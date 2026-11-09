-- ============================================================================
-- Dashboard views (Tableau)
--
-- Presentation layer for the stakeholder dashboard. Each dash_* view is
-- small, uses plain-English labels, and covers only the current model (the
-- model_version of the most recent monitoring rollup). The views are
-- exported to Google Sheets / CSV for Tableau, so the workbook does not
-- need a live BigQuery connection.
--
-- Run once (CREATE OR REPLACE); the views read the monitoring tables, so
-- they stay current after each run_monitoring.sh refresh.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- dash_feature_labels
-- ----------------------------------------------------------------------------
-- Plain-English names for the monitored features. Shared by the feature
-- drift and alert views so both use the same wording.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.dash_feature_labels` AS
SELECT feature_name, feature_label, feature_group
FROM UNNEST([
  STRUCT('loan_amount'         AS feature_name, 'Loan amount'                   AS feature_label, 'Loan'            AS feature_group),
  STRUCT('interest_rate',       'Interest rate',                 'Loan'),
  STRUCT('grade',               'Lending Club grade',            'Loan'),
  STRUCT('purpose',             'Loan purpose',                  'Loan'),
  STRUCT('initial_list_status', 'Listing type (whole/fractional)','Loan'),
  STRUCT('annual_income',       'Annual income',                 'Borrower'),
  STRUCT('dti',                 'Debt-to-income ratio',          'Borrower'),
  STRUCT('home_ownership',      'Home ownership',                'Borrower'),
  STRUCT('verification_status', 'Income verification',           'Borrower'),
  STRUCT('revol_bal',           'Credit card balance',           'Credit history'),
  STRUCT('revol_util',          'Credit card utilisation',       'Credit history'),
  STRUCT('total_acc',           'Number of credit accounts',     'Credit history')
]);

-- ----------------------------------------------------------------------------
-- dash_scored
-- ----------------------------------------------------------------------------
-- Loan-level helper (not exported): the latest scoring run of the current
-- model, joined to features for the outcome and loan term.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.dash_scored` AS
WITH current_model AS (
  SELECT model_version
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_rollups`
  ORDER BY ts DESC
  LIMIT 1
),
latest_run AS (
  SELECT p.model_version, p.split, MAX(p.ts) AS max_ts
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.predictions` p
  JOIN current_model USING (model_version)
  GROUP BY p.model_version, p.split
)
SELECT
  p.model_version,
  p.split,
  p.loan_id,
  FORMAT_DATE('%Y-%m', p.issue_date) AS issue_month,
  f.term_months,
  p.p_default,
  f.label
FROM `project-01523b1d-fc19-4c00-97e.creditrisk.predictions` p
JOIN latest_run l
  ON p.model_version = l.model_version
 AND p.split         = l.split
 AND p.ts            = l.max_ts
JOIN `project-01523b1d-fc19-4c00-97e.creditrisk.features` f
  ON p.loan_id = f.loan_id
WHERE p.p_default IS NOT NULL
  AND f.label    IS NOT NULL;

-- ----------------------------------------------------------------------------
-- dash_risk_bands  (pages 2 and 4)
-- ----------------------------------------------------------------------------
-- Loans ranked by predicted PD and cut into 100 equal bands per split
-- (band 1 = riskiest 1%). Bands are set across all loans, then broken out
-- by term, so filtering to one term shows how a book-wide cut-off falls on
-- that term. In Tableau, "decline the riskiest X%" is risk_band <= X.
-- loan_id breaks ties so band assignment is deterministic.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.dash_risk_bands` AS
WITH banded AS (
  SELECT
    *,
    NTILE(100) OVER (PARTITION BY split ORDER BY p_default DESC, loan_id) AS risk_band
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.dash_scored`
)
SELECT
  model_version,
  split,
  risk_band,
  CONCAT(CAST(term_months AS STRING), ' months') AS loan_term,
  COUNT(*)                AS loans,
  SUM(label)              AS defaults,
  COUNT(*) - SUM(label)   AS repaid,
  SUM(p_default)          AS predicted_defaults,   -- sum of PDs; / loans = avg predicted rate
  MIN(p_default)          AS min_pd,
  MAX(p_default)          AS max_pd
FROM banded
GROUP BY model_version, split, risk_band, term_months;

-- ----------------------------------------------------------------------------
-- dash_score_trend  (page 1)
-- ----------------------------------------------------------------------------
-- Predicted vs actual default rate by issue month, with the PD percentiles
-- from score_drift for the tooltip.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.dash_score_trend` AS
WITH actuals AS (
  SELECT
    model_version,
    split,
    issue_month,
    COUNT(*)       AS loans,
    AVG(p_default) AS predicted_default_rate,
    AVG(label)     AS actual_default_rate
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.dash_scored`
  GROUP BY model_version, split, issue_month
)
SELECT
  a.model_version,
  a.split,
  PARSE_DATE('%Y-%m', a.issue_month) AS month_start,
  a.issue_month,
  a.loans,
  a.predicted_default_rate,
  a.actual_default_rate,
  s.p50 AS median_pd,
  s.p90 AS p90_pd
FROM actuals a
LEFT JOIN `project-01523b1d-fc19-4c00-97e.creditrisk.score_drift_latest` s
  ON a.model_version = s.model_version
 AND a.split         = s.split
 AND a.issue_month   = s.issue_month;

-- ----------------------------------------------------------------------------
-- dash_feature_drift  (page 3)
-- ----------------------------------------------------------------------------
-- One row per (split, feature, month). Status uses the same month-over-month
-- rules and thresholds as sql/monitoring/11 and 12, so a red cell on the
-- heatmap always has a matching alert:
--   numeric:     relative change in mean  >= 10% WARN, >= 20% CRITICAL
--   categorical: change in top-value share >= 5 pts WARN, >= 8 pts CRITICAL
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.dash_feature_drift` AS
WITH current_model AS (
  SELECT model_version
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_rollups`
  ORDER BY ts DESC
  LIMIT 1
),
fd AS (
  SELECT
    f.*,
    LAG(f.mean)               OVER w AS prev_mean,
    LAG(f.top_category_share) OVER w AS prev_share,
    FIRST_VALUE(f.mean)               OVER w AS first_mean,
    FIRST_VALUE(f.top_category_share) OVER w AS first_share
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.feature_drift_latest` f
  JOIN current_model USING (model_version)
  WINDOW w AS (PARTITION BY f.split, f.feature_name ORDER BY f.issue_month)
),
changes AS (
  SELECT
    *,
    CASE feature_type
      WHEN 'numeric'     THEN SAFE_DIVIDE(ABS(mean - prev_mean), ABS(prev_mean))
      WHEN 'categorical' THEN ABS(top_category_share - prev_share)
    END AS change_vs_prev_month,
    CASE feature_type
      WHEN 'numeric'     THEN SAFE_DIVIDE(mean - first_mean, ABS(first_mean))
      WHEN 'categorical' THEN top_category_share - first_share
    END AS change_vs_first_month
  FROM fd
)
SELECT
  c.model_version,
  c.split,
  PARSE_DATE('%Y-%m', c.issue_month) AS month_start,
  c.issue_month,
  c.feature_name,
  COALESCE(l.feature_label, c.feature_name) AS feature_label,
  COALESCE(l.feature_group, 'Other')        AS feature_group,
  c.feature_type,
  c.n AS loans,
  c.null_rate,
  c.mean,
  CASE
    WHEN c.feature_name = 'initial_list_status' AND c.top_category = 'w' THEN 'Whole loan'
    WHEN c.feature_name = 'initial_list_status' AND c.top_category = 'f' THEN 'Fractional'
    ELSE c.top_category
  END AS top_category,
  c.top_category_share,
  c.change_vs_prev_month,
  c.change_vs_first_month,
  CASE c.feature_type
    WHEN 'numeric'     THEN '% change in average'
    WHEN 'categorical' THEN 'change in share of most common value'
  END AS change_measure,
  CASE
    WHEN c.change_vs_prev_month IS NULL THEN 'Baseline'
    WHEN c.feature_type = 'numeric'     AND c.change_vs_prev_month >= 0.20 THEN 'Critical'
    WHEN c.feature_type = 'numeric'     AND c.change_vs_prev_month >= 0.10 THEN 'Warning'
    WHEN c.feature_type = 'categorical' AND c.change_vs_prev_month >= 0.08 THEN 'Critical'
    WHEN c.feature_type = 'categorical' AND c.change_vs_prev_month >= 0.05 THEN 'Warning'
    ELSE 'Stable'
  END AS status
FROM changes c
LEFT JOIN `project-01523b1d-fc19-4c00-97e.creditrisk.dash_feature_labels` l
  USING (feature_name);

-- ----------------------------------------------------------------------------
-- dash_alerts  (pages 1 and 4)
-- ----------------------------------------------------------------------------
-- Alerts from the most recent run of each check for the current model, with
-- a plain-English message. Demo rows and older model versions are excluded.
-- Note: a check that finds nothing writes no rows, so an alert stays here
-- until that check fires again or the model changes.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.dash_alerts` AS
WITH current_model AS (
  SELECT model_version
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_rollups`
  ORDER BY ts DESC
  LIMIT 1
),
latest AS (
  SELECT a.*
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_alerts` a
  JOIN current_model USING (model_version)
  WHERE a.alert_type NOT LIKE 'demo%'
  QUALIFY a.ts = MAX(a.ts) OVER (PARTITION BY a.alert_type)
)
SELECT
  a.ts AS checked_at,
  a.model_version,
  a.split,
  CASE a.split WHEN 'test' THEN 'Monitored period' ELSE 'Validation period' END AS period,
  PARSE_DATE('%Y-%m', a.issue_month) AS month_start,
  a.issue_month,
  a.alert_type,
  CASE UPPER(a.severity) WHEN 'CRITICAL' THEN 'Critical' WHEN 'WARN' THEN 'Warning' ELSE 'Info' END AS severity,
  CASE UPPER(a.severity) WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END AS severity_rank,
  CASE a.alert_type WHEN 'score_drift_p90' THEN 'Risk scores' ELSE COALESCE(l.feature_label, a.entity) END AS what_changed,
  CASE a.alert_type
    WHEN 'score_drift_p90' THEN FORMAT(
      'Predicted risk for the riskiest 10%% of loans moved %.1f points from the previous month (limit %.0f).',
      a.value * 100, a.threshold * 100)
    WHEN 'numeric_mean_drift' THEN FORMAT(
      'Average %s changed %.0f%% from the previous month (limit %.0f%%).',
      LOWER(COALESCE(l.feature_label, a.entity)), a.value * 100, a.threshold * 100)
    WHEN 'categorical_share_drift' THEN FORMAT(
      'Share of the most common %s value moved %.0f points from the previous month (limit %.0f).',
      LOWER(COALESCE(l.feature_label, a.entity)), a.value * 100, a.threshold * 100)
    ELSE a.details
  END AS message,
  a.value,
  a.threshold,
  a.details AS technical_details
FROM latest a
LEFT JOIN `project-01523b1d-fc19-4c00-97e.creditrisk.dash_feature_labels` l
  ON a.entity = l.feature_name;

-- ----------------------------------------------------------------------------
-- dash_summary  (page 1 tiles, page 4 metrics)
-- ----------------------------------------------------------------------------
-- One row per split for the current model. Status: 'Action needed' if any
-- critical alert, 'Watch' if any warning, otherwise 'Healthy'.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.dash_summary` AS
WITH current_model AS (
  SELECT model_version
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_rollups`
  ORDER BY ts DESC
  LIMIT 1
),
rollups AS (
  SELECT r.*
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_rollups_latest` r
  JOIN current_model USING (model_version)
),
metrics AS (
  SELECT m.split, m.roc_auc, m.pr_auc, m.brier
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.model_metrics` m
  JOIN current_model USING (model_version)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY m.split ORDER BY m.ts DESC) = 1
),
predicted AS (
  SELECT split, AVG(p_default) AS predicted_default_rate
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.dash_scored`
  GROUP BY split
),
alerts AS (
  SELECT
    split,
    COUNTIF(severity = 'Critical') AS critical_alerts,
    COUNTIF(severity = 'Warning')  AS warning_alerts
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.dash_alerts`
  GROUP BY split
),
joined AS (
  SELECT
    r.model_version,
    r.split,
    r.ts AS refreshed_at,
    r.n  AS loans,
    r.base_rate AS actual_default_rate,
    p.predicted_default_rate,
    r.top_5pct_default_rate,
    r.lift_at_1pct, r.lift_at_5pct, r.lift_at_10pct,
    r.recall_at_1pct, r.recall_at_5pct, r.recall_at_10pct,
    m.roc_auc, m.pr_auc, m.brier,
    COALESCE(a.critical_alerts, 0) AS critical_alerts,
    COALESCE(a.warning_alerts, 0)  AS warning_alerts
  FROM rollups r
  LEFT JOIN metrics   m USING (split)
  LEFT JOIN predicted p USING (split)
  LEFT JOIN alerts    a USING (split)
)
SELECT
  *,
  CASE
    WHEN critical_alerts > 0 THEN 'Action needed'
    WHEN warning_alerts  > 0 THEN 'Watch'
    ELSE 'Healthy'
  END AS status,
  CASE
    WHEN critical_alerts > 0 THEN FORMAT(
      '%d critical data change(s) found. Review the alerts before relying on scores for the affected months.',
      critical_alerts)
    WHEN warning_alerts > 0 THEN FORMAT(
      'The model is ranking risk well, but %d input(s) changed more than usual. Worth watching.',
      warning_alerts)
    ELSE 'The model is ranking risk well and no unusual data changes were found.'
  END AS headline,
  FORMAT('The riskiest 5%% of loans default at %.1f× the normal rate.', lift_at_5pct)   AS tile_lift,
  FORMAT('The riskiest 10%% of loans hold %.0f%% of all defaults.', recall_at_10pct * 100) AS tile_capture,
  FORMAT('Predicted %.1f%% default rate vs %.1f%% actual.',
         predicted_default_rate * 100, actual_default_rate * 100)                        AS tile_calibration
FROM joined;
