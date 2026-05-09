# Model Card — Credit Risk Probability of Default (PD)

## Overview
This model predicts the probability that a Lending Club loan will default
(`p_default`), using application-time loan and credit bureau attributes. It is
trained and evaluated using a strict time-based split (train on past, test
on future) to reflect real deployment conditions.

- **Model family:** Gradient-boosted trees (XGBoost) with early stopping
- **Output:** Calibrated probability `p_default ∈ [0, 1]`
- **Calibration:** Isotonic regression on a held-out validation slice
  (`CalibratedClassifierCV` with a `FrozenEstimator` wrapper to ensure the
  base model is not refit during calibration)
- **Best iteration:** ~1,400 trees (selected by early stopping on validation logloss)

---

## Intended use
- **Primary:** Risk ranking for review-capacity planning (top-K risk bucket
  prioritization)
- **Secondary:** Monitoring portfolio-level risk trends over time
- **Tertiary:** Demonstration of MLOps-style monitoring on GCP (portfolio project)

**Not intended for:**
- Production underwriting decisions
- Use with personal/regulated data without governance, fairness review, and
  model risk management
- Fairness or equal-opportunity compliance claims (not evaluated here)

---

## Target variable (label)

Binary label derived from `loan_status` at the data snapshot date:

--------------------------------------------------------------------------------
| `loan_status` | Label | Rationale |
--------------------------------------------------------------------------------
| Charged Off | 1 | Realised default — clearest positive |
| Default | 1 | Formally defaulted |
| Late (31-120 days) | 1 | Severe delinquency, high probability of progressing to charge-off |
| Late (16-30 days) | 1 | Early delinquency; treated as adverse outcome because the operational use case is flagging loans for review, where early-stage delinquency is the actionable signal |
| Fully Paid | 0 | Realised non-default — clearest negative |
| Current | excluded (NULL) | Outcome not yet realised — see "Label maturity" below |
| In Grace Period / Issued | excluded (NULL) | Outcome not yet realised |
| Does not meet the credit policy: ... | excluded (NULL) | Different population from the current credit policy; mixing them would bias the model |

### Label maturity / right-censoring (key methodological note)
Loan outcomes take time to be realised. A loan issued recently may still be
`Current` at the snapshot date but could still default in the future. Naively
labelling `Current` as 0 (non-default) would inflate the negative class with
loans whose outcome is genuinely unknown, biasing the model toward
"non-default" predictions and producing optimistic but misleading metrics.

**Mitigations applied:**
1. **Exclude `Current` loans from the label.** They are dropped via `NULL`
   labels in `02_build_features.sql` and filtered out in the `clean` CTE.
2. **Maturity guard via issue date cutoff:** only loans issued on or before
   `2017-12-01` are included, ensuring even 60-month-term loans have had ~7+
   years to mature by the data snapshot date.
3. **Strict time-based split** by `issue_date` so train sees no
   information from the future.
4. **Ranking-based metrics** (Lift@K, Recall@K) are emphasized alongside
   absolute metrics because they remain meaningful when class prevalence
   shifts across cohorts.

After these filters, the realised base default rate is ~26–28% across the
three splits, which is consistent with Lending Club's published long-run
default behaviour for matured loans.

---

## Data + features

**Source:** Lending Club public loan-level dataset, loaded into
`creditrisk.loans_raw` in BigQuery.

### Feature set
Aligned to the four pillars of consumer credit risk:

**Capacity (can the borrower afford to repay?)**
- `loan_amount`, `installment`, `term_months`
- `annual_income`, `dti`

**Credit history (how have they handled credit before?)**
- `fico_low`, `fico_high` (FICO at application)
- `delinq_2yrs`, `pub_rec`
- `credit_history_years` (derived: `DATE_DIFF(issue_date, earliest_cr_line, YEAR)`)

**Utilization (how stretched are they currently?)**
- `revol_bal`, `revol_util`
- `open_acc`, `total_acc`

**Velocity (are they credit-hungry recently?)**
- `inq_last_6mths`

**Categorical / contextual**
- `grade`, `home_ownership`, `purpose`, `verification_status`,
  `initial_list_status`, `emp_length`

### Excluded features (leakage)
Lending Club's dataset contains many post-origination fields that would leak
the outcome. The following are deliberately never used as features:
- Payment-flow columns: `total_pymnt`, `total_rec_prncp`, `total_rec_int`,
  `total_rec_late_fee`, `recoveries`, `collection_recovery_fee`
- Payment-timing columns: `last_pymnt_d`, `last_pymnt_amnt`, `next_pymnt_d`
- Outstanding balance: `out_prncp`, `out_prncp_inv`
- Post-origination credit pulls: `last_fico_range_low`, `last_fico_range_high`,
  `last_credit_pull_d`
- Hardship and settlement program columns

### Note on `grade` and `int_rate`
Both `grade` and `interest_rate` reflect Lending Club's own underwriting
assessment at origination. They are kept as features because they capture
real signal, but the model's incremental lift over `grade` alone would be
the more rigorous question to evaluate in a production setting.

### Preprocessing
- Type casting via `SAFE_CAST` and `SAFE.PARSE_DATE` in BigQuery SQL
- Sanity filters: `annual_income > 0`, `dti BETWEEN 0 AND 100`
- Defensive deduplication on `loan_id`
- One-hot encoding for categorical features (handled in the training pipeline
  via `ColumnTransformer` + `OneHotEncoder(handle_unknown="ignore")`)
- Numeric features passed through unchanged (XGBoost handles missing values
  natively)

### Time split
Strict time-based split by `issue_date` using `APPROX_QUANTILES`:
- **train:** oldest ~80% of rows by issue date
- **valid:** next ~10%
- **test:** newest ~10%

Note: this is a **row-quantile** split, not a calendar-uniform split. Because
Lending Club's origination volume grew over time, train concentrates on
earlier years and test on a narrower recent window. This is consistent with
real-world deployment (more recent data = smaller cohort) and is documented
here for transparency.

---

## Training procedure

1. Query `creditrisk.features` from BigQuery (using BigQuery Storage API for
   faster DataFrame downloads)
2. Fit XGBoost classifier on the `train` split with **early stopping** on
   `valid` (`n_estimators=2000`, `early_stopping_rounds=50`,
   `learning_rate=0.05`, `max_depth=4`, `tree_method="hist"`)
3. Wrap the trained pipeline with `FrozenEstimator` and calibrate
   probabilities using isotonic regression on the `valid` split
4. Evaluate on `valid` and `test`
5. Write metrics rows to `creditrisk.model_metrics`
6. Save model artifact (with `model_version` timestamp, `best_iteration`,
   feature lists, and metric snapshots) to `artifacts/model.joblib`

---

## Evaluation metrics

### Latest results (model version `20260430-002800`, trained on full dataset)

---------------------------------------------------
| Metric | VALID | TEST |
---------------------------------------------------
| ROC-AUC | 0.6969 | 0.7063 |
| PR-AUC | 0.4347 | 0.4539 |
| Brier score | 0.1758 | 0.1792 |
| Base rate | ~26% | ~28% |
| Top 5% default rate | 0.578 | 0.585 |
| Top 5% recall | 10.96% | 10.6% |

**Lift@5%** ≈ `top_5pct_default_rate / base_rate` ≈ 2.1× on test
(top 5% predictions capture defaults at ~2.1× the population base rate).

### Metric definitions
- **ROC-AUC:** ranking power; invariant to base rate. The primary metric for
  cross-cohort comparison.
- **PR-AUC:** precision-recall AUC; useful for imbalanced classes but scales
  with base rate.
- **Brier score:** mean squared error of probabilities; measures calibration
  quality. Lower is better. Bounded above by `base_rate × (1 - base_rate)`.
- **Top-K default rate:** observed default rate among the K% of loans with
  the highest predicted PD.
- **Lift@K:** top-K default rate ÷ base rate. The relative concentration of
  defaults in the top-K bucket.
- **Recall@K:** fraction of all defaults captured within the top-K bucket.

These metrics are surfaced in:
- `creditrisk.model_metrics` (raw evaluation)
- `creditrisk.monitoring_rollups` and its `_latest` view
- Looker Studio dashboard (Executive Summary + Lift/Recall page)

---

## Monitoring plan
Monitoring runs write to BigQuery for auditability and dashboards.

### Score drift (monthly)
From `creditrisk.score_drift`:
- `avg_pd`, `p50`, `p90`, `p99` of predicted PD by `issue_month`

**Purpose:** detect distribution shift in model scores over time; track
whether the portfolio's predicted risk is increasing or decreasing.

### Feature drift (monthly)
From `creditrisk.feature_drift`:
- Numeric features: `mean`, `std`, `min`, `max`, `null_rate`
- Categorical features: `top_category`, `top_category_share`, `entropy`

**Purpose:** detect upstream data changes — schema drift, missingness shifts,
population shifts, or newly-emerging categorical values.

### Alerts
Threshold-based alerts written to `creditrisk.monitoring_alerts`, including:
- Large month-over-month score-drift deltas (e.g., p90 shift > threshold)
- Large changes in numeric feature mean
- Large changes in categorical top-share
- Anomalies in null rate

---

## Limitations and known issues

1. **Fairness not evaluated.** No analysis of disparate impact across
   protected attributes. A production deployment would require this.
2. **No model explainability surface.** SHAP values or feature importance
   reports are not produced or surfaced. Worth adding for any real use.
3. **Single model artifact.** No challenger model or A/B framework.
4. **Manual model versioning.** Versions are timestamps; no link to git SHA
   or a model registry.
5. **`grade` and `int_rate` partially encode LC's own risk assessment** —
   incremental-lift analysis (model with vs. without these) is not currently
   produced.
6. **The row-quantile time split** concentrates train on earlier years.
   A calendar-uniform split (e.g., by half-year buckets) would be more
   robust for evaluating drift over fixed time intervals.
7. **Cloud Shell training.** Full training runs on Cloud Shell take
   ~10–15 minutes. For production, training should move to Vertex AI
   custom jobs or a properly-sized Compute Engine VM.

---

## Ethical / fairness considerations
This project does not include sensitive attributes or fairness evaluation.
In a real deployment:
- Disparate impact testing across protected classes would be required
- Model governance, explainability, and adverse action notice generation
  would be necessary
- Outcomes and policies would need to satisfy regulatory and institutional
  requirements (e.g., ECOA, FCRA in the US)

---

## Reproducibility

**One-command monitoring refresh:**
```
./run_monitoring.sh
```

**Artifacts:**
- `artifacts/model.joblib` — versioned model with metric snapshots and
  best-iteration metadata embedded
- BigQuery tables (`model_metrics`, `predictions`, `score_drift`,
  `feature_drift`, `monitoring_alerts`) provide an auditable history of
  every run
