# Credit Risk Monitoring on GCP (BigQuery + XGBoost + Looker Studio)

End-to-end credit risk modeling and monitoring pipeline built on Google Cloud
Platform, using the Lending Club public dataset.

The project demonstrates a complete MLOps loop:

ingest → feature engineering (BigQuery SQL) → calibrated XGBoost model →
batch scoring → drift monitoring → threshold-based alerting → Looker Studio
dashboard.

The architecture is **BigQuery-first**: every artifact (features, predictions,
metrics, drift, alerts) lives in BigQuery, giving the system an auditable,
queryable history of every run.

---

## Latest results

Trained on full Lending Club public dataset (~1.3M loans, issued through
2017-12-01) using a strict time-based train / valid / test split.


| Metric | VALID | **TEST** |
|---|---|---|
| ROC-AUC | 0.6969 | **0.7063** |
| PR-AUC | 0.4347 | 0.4539 |
| Brier score | 0.1758 | 0.1792 |
| Base default rate | ~26% | ~28% |
| Top 5% default rate | 0.578 | 0.585 |
| Top 5% recall | 11.0% | 10.6% |
| **Lift @ 5%** | 2.19× | **2.12×** |

`Lift@5% = top 5% default rate / population base rate` — the top 5% of loans
ranked by predicted PD default at ~2.1× the population rate, which is useful
for review-capacity prioritization.

Model: XGBoost with isotonic-regression calibration on a held-out validation
slice; early stopping at 1,390 of 2,000 trees on validation logloss.

---

## What this project demonstrates

- **Time-based train / valid / test split** by `issue_date` (no leakage from
  the future)
- **Probability calibration** via isotonic regression on a held-out validation
  slice, using `CalibratedClassifierCV` with a `FrozenEstimator` wrapper to
  prevent the base model from being refit
- **Honest label handling for right-censoring**: loans with unrealised
  outcomes (`Current`, `In Grace Period`, etc.) are excluded; only matured
  loans contribute to training
- **Standard credit risk feature set** organized around the four pillars:
  capacity, credit history, utilization, velocity
- **Operational monitoring as a first-class concern**:
  - Ranking performance rollups (Lift@K, Recall@K)
  - Score drift (p50 / p90 / p99 / avg by month)
  - Feature drift (numeric stats + categorical share / entropy)
  - Threshold-based alerts written to BigQuery
- **GCP-native workflow**: BigQuery as the system of record, Looker Studio
  for visualization

See [`MODEL_CARD.md`](./MODEL_CARD.md) for the full label definition,
limitations, and methodology notes. See [`ARCHITECTURE.md`](./ARCHITECTURE.md)
for the data flow and table responsibilities.

---

## Repo structure

```
creditrisk-gcp/
├── README.md
├── ARCHITECTURE.md            # data flow + table responsibilities
├── MODEL_CARD.md              # label definition, metrics, limitations
├── run_monitoring.sh          # one-command monitoring refresh
├── start.sh                   # session bootstrap (gcloud config, env vars)
├── data/                      # local CSV input (loans.csv, gitignored)
├── artifacts/                 # trained model artifact (model.joblib, gitignored)
├── infra/
│   └── README_setup.md        # GCP project setup notes
├── sql/
│   ├── 01_create_tables.sql   # core BigQuery table DDL
│   ├── 02_build_features.sql  # feature engineering + label + time split
│   ├── 03_monitoring_tables.sql
│   ├── 04_feature_drift.sql   # feature-drift insert query
│   ├── 05_score_drift.sql
│   ├── 06_monitoring_rollups.sql
│   └── monitoring/
│       ├── 10_alert_score_p90.sql
│       ├── 11_alert_numeric_mean.sql
│       └── 12_alert_categorical_share.sql
├── src/
│   ├── ingest/
│   │   └── upload_and_load.py # CSV → BigQuery
│   ├── train/
│   │   ├── train.py           # train + calibrate + write metrics
│   │   ├── score_to_bigquery.py
│   │   ├── evaluate.py
│   │   └── requirements.txt
│   └── explain/
│       └── reason_codes.py    # SHAP reason codes for declined applicants
└── tests/
    └── test_reason_codes.py   # synthetic end-to-end check (no BigQuery)
```

---

## Quickstart (Cloud Shell)

### 0) Bootstrap session
```bash
cd ~/creditrisk-gcp
source start.sh
```
This sets `gcloud` config, exports `PROJECT_ID` and `BQ_DATASET`, and
activates the Python virtual environment.

### 1) Python environment (first run only)
```bash
python -m venv .venv
source .venv/bin/activate
pip install -r src/train/requirements.txt
```

### 2) Create BigQuery tables (core + monitoring)
```bash
bq query --use_legacy_sql=false < sql/01_create_tables.sql
bq query --use_legacy_sql=false < sql/03_monitoring_tables.sql
```

### 3) Load raw dataset (CSV → BigQuery)
Place the Lending Club CSV at `data/loans.csv`, then:
```bash
python -m src.ingest.upload_and_load
```

### 4) Build features, label, and time split
```bash
bq query --use_legacy_sql=false < sql/02_build_features.sql
```
This produces `creditrisk.features` with the train / valid / test split.

### 5) Train calibrated model and log metrics
```bash
python src/train/train.py
```
Full run takes ~10–15 minutes on Cloud Shell. For a smoke test, set
`BQ_LIMIT=20000` to subsample.

### 6) Score valid + test into BigQuery
```bash
export SCORE_SPLIT=valid && python src/train/score_to_bigquery.py
export SCORE_SPLIT=test  && python src/train/score_to_bigquery.py
```

### 7) Run monitoring (one command)
```bash
chmod +x run_monitoring.sh
./run_monitoring.sh
```

---

## Key BigQuery outputs

### Core
- `creditrisk.loans_raw` — raw Lending Club dataset
- `creditrisk.features` — engineered features + label + time split
- `creditrisk.model_metrics` — evaluation metrics per training run (valid / test)
- `creditrisk.predictions` — scored PDs with `model_version`, `split`,
  `issue_date`, `ts`

### Monitoring
- `creditrisk.monitoring_rollups` (+ `_latest` view) — Lift@K / Recall@K
  rollups by run
- `creditrisk.score_drift` (+ `_latest` view) — PD distribution drift by month
- `creditrisk.feature_drift` (+ `_latest` view) — feature-level drift stats
  by month
- `creditrisk.monitoring_alerts` — threshold-based alerts (score and feature
  drift)

---

## Looker Studio dashboard

Five-page Looker Studio dashboard surfacing model performance and monitoring,
backed by BigQuery `_latest` views.

### Executive Summary
![Executive Summary](docs/screenshots/01_executive_summary.png)

### Lift / Recall Performance
![Lift / Recall Performance](docs/screenshots/02_lift_recall_performance.png)

### Score Drift
![Score Drift](docs/screenshots/03_score_drift.png)

### Feature Drift
![Feature Drift](docs/screenshots/04_feature_drift.png)

### Alerts
![Alerts](docs/screenshots/05_alerts.png)

---

### Calibration

![Reliability diagram](docs/reliability_diagram.png)

Isotonic calibration reduces test Brier from X to Y. Boosted trees rank well
but produce distorted probabilities; since the model output feeds an expected
loss calculation (PD x LGD x EAD), probability quality matters as much as
rank order.

---

## Methodology highlights

- **Calibration via `FrozenEstimator` (sklearn ≥ 1.6).** The base XGBoost
  pipeline is fit on the train split, then wrapped with `FrozenEstimator` so
  that `CalibratedClassifierCV` only fits the isotonic calibrator on top of
  the frozen base model's predictions on the valid split. This keeps train,
  calibrate, and test fully separated.
- **Maturity guard.** Only loans issued on or before `2017-12-01` are kept,
  so even 60-month-term loans have had ~7+ years to mature by the data
  snapshot date. Combined with excluding `Current` loans from the label,
  this avoids the right-censoring bias that inflates portfolio-grade
  Lending Club models.
- **Early stopping.** Training uses `n_estimators=2000` with
  `early_stopping_rounds=50` on validation logloss; the best iteration
  (~1,400 trees) is selected automatically.
- **Leakage discipline.** All post-origination Lending Club fields
  (`total_pymnt`, `recoveries`, `last_fico_range_*`, `hardship_*`,
  `settlement_*`, etc.) are excluded from features. See `MODEL_CARD.md` for
  the full list.

---

## Reason codes for declined applicants

A lender that declines an application has to tell the applicant the main
reasons. `src/explain/reason_codes.py` generates those reasons from the model.

1. **Decide who is declined.** Score applicants with the calibrated model and
   decline those above a PD cut-off (`PD_CUTOFF`) or the riskiest share
   (`DECLINE_RATE`, default 10%, a stand-in for a business-set cut-off).
2. **Explain each score.** Exact TreeSHAP via XGBoost's built-in
   `pred_contribs`, on the base model's log-odds. Isotonic calibration is
   monotone, so it never changes which way a feature pushes risk.
3. **Fold one-hot columns back** into their original feature (SHAP values are
   additive, so this is exact).
4. **Group and translate.** Related features become one reason (e.g.
   `fico_low` + `fico_high` → "Credit score is lower than for approved
   applicants"), across 14 reason codes.
5. **Exclude non-applicant factors.** Lending Club's grade, interest rate and
   listing type are the lender's own assessment, not facts about the
   applicant, so they are never reported.
6. **Report the top four reasons** that pushed each declined applicant's risk up.

**Built-in checks:** contributions must add up to the model's output; share
of each explanation falling on non-reportable features; share of declines
with no reportable reason; and whether each feature moves risk in the
expected direction (e.g. higher DTI → higher risk).

**Which model:** reason codes use the model trained without grade and interest
rate (`FEATURE_SET=no_lc`). In the feature ablation it matched the full model
on test AUC (0.7064 vs 0.7059), and every reason it gives describes the
applicant. With the full model, the grade absorbs much of the explanation.

```bash
FEATURE_SET=no_lc ARTIFACT_DIR=artifacts/no_lc python src/train/train.py
ARTIFACT_PATH=artifacts/no_lc/model.joblib SCORE_SPLIT=test \
    python src/explain/reason_codes.py      # writes artifacts/reason_codes/
python tests/test_reason_codes.py           # synthetic end-to-end check, no BigQuery needed
```

<!-- TODO: add results from the real no_lc run (non-reportable share, most common first reason, direction check) -->

---

## Limitations
This is a portfolio / demonstration project. It is **not** intended for
production underwriting decisions. Notably:

- No fairness / disparate-impact evaluation
- Explainability is limited to per-applicant reason codes; no global
  feature-importance report or monotonic constraints yet
- No challenger model or A/B framework
- Manual model versioning (timestamps, no git SHA linkage or model registry)
- Training runs on Cloud Shell; production should use Vertex AI custom jobs
  or appropriately-sized Compute Engine VMs

See `MODEL_CARD.md` § Limitations for the complete list.

---

## Tech stack
- **Cloud:** Google Cloud Platform (BigQuery, Cloud Shell, Looker Studio)
- **Modeling:** Python, scikit-learn, XGBoost
- **Data:** Lending Club public loan-level dataset
- **Monitoring:** BigQuery SQL + Python orchestration
