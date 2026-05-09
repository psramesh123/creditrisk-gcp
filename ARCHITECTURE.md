# Architecture

This project uses BigQuery as the system of record for everything: raw
data, engineered features, model predictions, evaluation metrics, drift
statistics, and alerts. Python scripts handle ingestion, ctraining, soring,
and monitoring orchestration. Visualization is in Looker Studio.

The design is deliberately simple — no Vertex AI Pipelines, no Cloud
Composer, no Cloud Run service — because the goal is an auditable,
queryable, reproducible monitoring loop, not a maximally cloud-native one.
Every artifact a reviewer might want to inspect lives in a BigQuery table
they can `SELECT` from.

---

## High-level flow

```
   ┌──────────────┐
   │  loans.csv   │   Lending Club public dataset
   └──────┬───────┘
          │  src/ingest/upload_and_load.py
          ▼
   ┌────────────────────────┐
   │ creditrisk.loans_raw   │   raw, mostly STRING types
   └──────┬─────────────────┘
          │  sql/02_build_features.sql
          ▼
   ┌────────────────────────┐
   │ creditrisk.features    │   typed, labelled, time-split
   └──────┬─────────────────┘
          │  src/train/train.py
          ▼
   ┌────────────────────────┐    ┌─────────────────────────────┐
   │ artifacts/model.joblib │    │ creditrisk.model_metrics    │
   └──────┬─────────────────┘    └─────────────────────────────┘
          │  src/train/score_to_bigquery.py
          ▼
   ┌────────────────────────┐
   │ creditrisk.predictions │   PDs partitioned by run ts
   └──────┬─────────────────┘
          │  run_monitoring.sh (orchestrates SQL + Python)
          ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ score_drift │ feature_drift │ monitoring_rollups │ alerts   │
   └──────┬──────────────────────────────────────────────────────┘
          │  Looker Studio (queries *_latest views)
          ▼
   ┌────────────────────────┐
   │ Dashboard              │
   └────────────────────────┘
```

---

## Stage-by-stage detail

### 1) Raw data → BigQuery
- Lending Club CSV (loan-level, ~150 columns) loaded into
  `creditrisk.loans_raw`
- Most fields are loaded as `STRING` to be defensive about parsing; type
  casting happens in feature engineering
- `src/ingest/upload_and_load.py` handles the CSV → BigQuery load via the
  BigQuery Python client

### 2) Feature engineering, labelling, and time split (BigQuery SQL)
`sql/02_build_features.sql` builds `creditrisk.features` in a single
multi-CTE query:

- **`base`** — type cast every relevant column with `SAFE_CAST` /
  `SAFE.PARSE_DATE`; build the binary label from `loan_status`; extract
  `term_months` from the `' 36 months'` / `' 60 months'` strings
- **`dedup`** — `QUALIFY ROW_NUMBER() OVER (PARTITION BY loan_id ...) = 1`
  as a defensive deduplication
- **`clean`** — apply maturity guard (`issue_date <= 2017-12-01`), exclude
  rows with NULL labels (which removes `Current`, `Issued`, `In Grace
  Period`, and `Does not meet credit policy` loans), apply sanity filters
  (`annual_income > 0`, `dti BETWEEN 0 AND 100`); also derive
  `credit_history_years` from `earliest_cr_line_date`
- **`cutoffs`** — compute the 80th and 90th percentile of `issue_date`
  using `APPROX_QUANTILES`
- **`splits`** — assign each row to `train`, `valid`, or `test` based on
  whether its `issue_date` is before the 80th, 90th, or after the 90th
  percentile

The result is a typed, labelled, deduped, time-split table ready for
training.

**Why this design:**
- Doing the split in SQL means it's auditable and reproducible — anyone can
  query `creditrisk.features` and see which rows are in which split
- Doing it server-side avoids pulling millions of rows into Python just to
  partition them
- The label logic is in one place; if it changes, only the SQL needs to
  change and downstream tables can be rebuilt deterministically

### 3) Training (Python)
`src/train/train.py` runs:

1. Load all three splits from BigQuery using the **BigQuery Storage API**
   (`create_bqstorage_client=True`) for ~3× faster DataFrame downloads
2. Build a sklearn `Pipeline` with `ColumnTransformer` (one-hot encoding
   for categoricals, passthrough for numerics) wrapping an `XGBClassifier`
3. Fit the preprocessor on train, transform train and valid, then fit
   XGBoost with **early stopping on validation logloss**
   (`n_estimators=2000`, `early_stopping_rounds=50`,
   `learning_rate=0.05`, `max_depth=4`, `tree_method="hist"`)
4. Wrap the trained pipeline with `FrozenEstimator` (sklearn ≥ 1.6) and
   calibrate probabilities via isotonic regression on the valid split.
   The `FrozenEstimator` wrapper ensures `CalibratedClassifierCV` only fits
   the isotonic calibrator — the base model is not refit during calibration.
5. Evaluate on valid and test; compute ROC-AUC, PR-AUC, Brier, plus
   Top-K default rate, Lift@K, and Recall@K for K ∈ {1%, 5%, 10%}
6. Write metric rows to `creditrisk.model_metrics`
7. Save the model artifact (model + version + best iteration + feature
   lists + metric snapshots) to `artifacts/model.joblib`

**Why these design choices:**
- Splitting the pipeline open to fit XGBoost directly with `eval_set` is
  the only clean way to use early stopping inside a sklearn `Pipeline`;
  the pipeline is reassembled afterward so downstream code sees a normal
  sklearn object
- `FrozenEstimator` is the modern (sklearn ≥ 1.6) replacement for the
  removed `cv="prefit"` parameter; it's the correct way to keep train,
  calibrate, and test fully separated
- Writing metrics to BigQuery (not just stdout or a local file) means every
  run is auditable and the dashboard always has historical data to compare
  against

### 4) Batch scoring (Python)
`src/train/score_to_bigquery.py`:

1. Loads `artifacts/model.joblib`
2. Reads the requested split from `creditrisk.features` (controlled by
   `SCORE_SPLIT` env var: `valid` or `test`)
3. Calls `model.predict_proba` to produce `p_default`
4. Inserts predictions into `creditrisk.predictions` with the run
   timestamp `ts`, `model_version`, `split`, `loan_id`, `issue_date`, and
   `p_default`

`creditrisk.predictions` is the source of truth for everything downstream
— rollups, drift, and alerts all query it.

### 5) Monitoring (BigQuery SQL + shell orchestration)
`run_monitoring.sh` is the one-command refresh:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd ~/creditrisk-gcp

# Score valid + test
export SCORE_SPLIT=valid && python src/train/score_to_bigquery.py
export SCORE_SPLIT=test  && python src/train/score_to_bigquery.py

# Feature drift refresh
bq query --use_legacy_sql=false < sql/feature_drift.sql

# Alerts
bq query --use_legacy_sql=false < sql/monitoring/10_alert_score_p90.sql
bq query --use_legacy_sql=false < sql/monitoring/11_alert_numeric_mean.sql
bq query --use_legacy_sql=false < sql/monitoring/12_alert_categorical_share.sql
```

Each monitoring SQL file is idempotent: it `INSERT`s a fresh batch of rows
keyed by run timestamp, so historical state is preserved.

### 6) Visualization (Looker Studio)
The dashboard queries `*_latest` views (e.g.
`creditrisk.monitoring_rollups_latest`) which select the most recent run
for a given `model_version` / `split`. This separation of *run history*
(in the base tables) from *current state* (in the views) keeps the
dashboard fast and the history queryable.

Pages:
- Executive Summary (VALID vs TEST KPIs)
- Lift / Recall Performance
- Score Drift over time
- Feature Drift (with feature selector)
- Alerts

---

## Key data assets

### Core
| Table | Purpose |
|---|---|
| `creditrisk.loans_raw` | Raw Lending Club loan records, mostly STRING types |
| `creditrisk.features` | Typed, labelled, deduped, time-split feature table |

### Model artifacts and scoring
| Asset | Purpose |
|---|---|
| `artifacts/model.joblib` | Serialized model + `model_version` + `best_iteration` + feature lists + metric snapshots |
| `creditrisk.predictions` | Batch-scored PDs (`ts`, `model_version`, `split`, `loan_id`, `issue_date`, `p_default`) |
| `creditrisk.model_metrics` | Per-run evaluation metrics (ROC-AUC, PR-AUC, Brier, Top-K rates, Recall@K) |

### Monitoring
| Table | Purpose |
|---|---|
| `creditrisk.monitoring_rollups` (+ `_latest`) | Lift@K / Recall@K rollups by run |
| `creditrisk.score_drift` (+ `_latest`) | PD distribution drift by `issue_month` (avg, p50, p90, p99) |
| `creditrisk.feature_drift` (+ `_latest`) | Per-feature stats by month (numeric: mean/std/min/max/null_rate; categorical: top_category, top_share, entropy) |
| `creditrisk.monitoring_alerts` | Threshold-based alerts (severity, type, observed value vs threshold) |

---

## Design choices (and why this looks like real MLOps)

**BigQuery-first.** Everything reproducible, queryable, and inspectable.
A reviewer can `SELECT * FROM creditrisk.model_metrics ORDER BY ts DESC`
and see every training run that ever happened. No state hidden in
notebooks or in someone's head.

**Strict time-based splits.** Train on past, validate on slightly newer
past, test on most recent past. Prevents temporal leakage and simulates
production deployment, where you always train on what you have and
evaluate on what comes next.

**Right-censoring handled at the data layer.** `Current` loans are
excluded from the label (their outcome is not yet realised), and the
maturity guard (`issue_date <= 2017-12-01`) ensures only loans that have
had time to mature are included. This is the single biggest methodological
trap in Lending Club modelling and is documented explicitly in the
feature SQL.

**Calibration with `FrozenEstimator`.** Probabilities are meaningful for
risk thresholds and capacity planning, not just rankings. The
`FrozenEstimator` wrapper guarantees the base model is fit on train,
calibrated on valid, and tested on test — three fully separate slices.

**Early stopping with headroom.** `n_estimators=2000` with
`early_stopping_rounds=50` lets the model find its own best size on
validation logloss, instead of being forced to a fixed (often suboptimal)
tree count.

**Leakage discipline.** All post-origination Lending Club fields
(`total_pymnt`, `recoveries`, `last_fico_range_*`, `hardship_*`,
`settlement_*`, etc.) are excluded from the feature set. See `MODEL_CARD.md`
for the complete list.

**Monitoring tables and alerts as first-class objects.** Drift and alerts
aren't a notebook artifact or a one-off chart — they're persistent BigQuery
tables with run history. This turns model evaluation from "what did we see
that one time" into an operational system you can reason about over time.

**Legacy column-name compatibility.** The `model_metrics` table has
columns named `top_K_precision` that actually store top-K *default rate*
(the metric definition was refined mid-project). Rather than break the
schema and lose run history, the new metric is mapped to the old column
name in the writer; the canonical name lives in the JSON `metrics_json`
field.

---

## What this project deliberately does not do

For honest scoping — these are intentional omissions, not gaps:

- **No Vertex AI Pipelines or Cloud Composer.** Orchestration is shell
  scripts. For a single-model, single-team project this is simpler and
  more transparent. A production deployment would replace `run_monitoring.sh`
  with a Vertex Pipeline or Composer DAG.
- **No real-time inference service.** `src/service/main.py` exists as
  scaffolding but is not deployed. Scoring is batch-only via
  `score_to_bigquery.py`. Production would add a Cloud Run / Vertex
  Endpoint serving layer.
- **No CI/CD.** No GitHub Actions, no automated tests on push. Production
  would add at minimum: linting, unit tests for label logic and drift
  calculations, and a smoke test of `train.py` with `BQ_LIMIT`.
- **No model registry.** Model versions are timestamps; the artifact is a
  local `.joblib` file. Production would use Vertex Model Registry or a
  GCS-backed registry with proper versioning and lineage.
- **No fairness evaluation.** Required for any real credit deployment;
  out of scope here. See `MODEL_CARD.md` § Limitations.
