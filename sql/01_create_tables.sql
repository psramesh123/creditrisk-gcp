----------------------------------------------------------------------------
-- 1. loans_raw
-- ----------------------------------------------------------------------------
-- Raw Lending Club loan-level data. Most fields are loaded as STRING to be
-- defensive about parsing inconsistencies in the source CSV; type casting
-- happens downstream in 02_build_features.sql via SAFE_CAST / SAFE.PARSE_DATE.
--
-- Schema covers the columns actually referenced by the feature builder.
-- The full Lending Club dataset has ~150 columns; many are intentionally
-- not used (post-origination payment columns are excluded as leakage).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `project-01523b1d-fc19-4c00-97e.creditrisk.loans_raw` (
  -- identifiers
  id                       STRING,
  member_id                STRING,
 
  -- loan terms
  loan_amnt                STRING,
  funded_amnt              STRING,
  funded_amnt_inv          STRING,
  term                     STRING,    -- ' 36 months' / ' 60 months'
  int_rate                 STRING,
  installment              STRING,
  grade                    STRING,
  sub_grade                STRING,
  issue_d                  STRING,    -- e.g. 'Dec-2017'
 
  -- borrower attributes
  emp_title                STRING,
  emp_length               STRING,
  home_ownership           STRING,
  annual_inc               STRING,
  verification_status      STRING,
  addr_state               STRING,
  zip_code                 STRING,
 
  -- loan purpose / listing
  purpose                  STRING,
  title                    STRING,
  initial_list_status      STRING,
  application_type         STRING,
 
  -- credit bureau: FICO
  fico_range_low           STRING,
  fico_range_high          STRING,
 
  -- credit bureau: history & accounts
  open_acc                 STRING,
  total_acc                STRING,
  pub_rec                  STRING,
  pub_rec_bankruptcies     STRING,
  earliest_cr_line         STRING,    -- e.g. 'Jan-2003'
  mort_acc                 STRING,
 
  -- credit bureau: delinquency & inquiries
  delinq_2yrs              STRING,
  inq_last_6mths           STRING,
 
  -- credit bureau: utilisation & balances
  revol_bal                STRING,
  revol_util               STRING,
 
  -- debt burden
  dti                      STRING,
 
  -- outcome
  loan_status              STRING
);
 
-- ----------------------------------------------------------------------------
-- 2. predictions
-- ----------------------------------------------------------------------------
-- Batch-scored predictions, one row per (loan_id, model_version, split, ts).
-- Partitioned by run timestamp so historical scoring runs are preserved
-- and the table doesn't grow unboundedly without partition pruning.
-- Clustered by model_version + split for efficient filtering in monitoring
-- and dashboard queries.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `project-01523b1d-fc19-4c00-97e.creditrisk.predictions` (
  ts             TIMESTAMP NOT NULL,
  model_version  STRING    NOT NULL,
  split          STRING    NOT NULL,    -- 'valid' or 'test'
  loan_id        STRING    NOT NULL,
  issue_date     DATE,
  p_default      FLOAT64
)
PARTITION BY DATE(ts)
CLUSTER BY model_version, split;
 
-- ----------------------------------------------------------------------------
-- 3. model_metrics
-- ----------------------------------------------------------------------------
-- Per-run evaluation metrics, written by src/train/train.py.
-- One row per (model_version, split, ts).
--
-- Note: columns named *_precision actually store the top-K default rate.
-- The naming is legacy from an earlier metric definition; the canonical
-- metric names live in the JSON metrics_json field. See MODEL_CARD.md for
-- the full metric definitions.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `project-01523b1d-fc19-4c00-97e.creditrisk.model_metrics` (
  ts                   TIMESTAMP,
  model_version        STRING,
  split                STRING,                -- 'valid' or 'test'
  metrics_json         STRING,                -- full metrics dict as JSON
 
  -- primary metrics
  roc_auc              FLOAT64,
  pr_auc               FLOAT64,
  brier                FLOAT64,
 
  -- top-K rates (legacy column names; store top-K default rate, not precision)
  top_1pct_precision   FLOAT64,
  top_1pct_recall      FLOAT64,
  top_5pct_precision   FLOAT64,
  top_5pct_recall      FLOAT64,
  top_10pct_precision  FLOAT64,
  top_10pct_recall     FLOAT64
);
 