-- ----------------------------------------------------------------------------
-- 1. score_drift
-- ----------------------------------------------------------------------------
-- PD distribution stats over time. One row per (run, model_version, split,
-- issue_month). Lets you see whether predicted risk is shifting over time
-- or across cohorts.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `project-01523b1d-fc19-4c00-97e.creditrisk.score_drift` (
  ts             TIMESTAMP NOT NULL,    -- when this drift snapshot was computed
  model_version  STRING    NOT NULL,
  split          STRING    NOT NULL,    -- 'valid' or 'test'
  issue_month    STRING    NOT NULL,    -- 'YYYY-MM'
  n              INT64,                 -- rows in this cohort
  avg_pd         FLOAT64,
  p50            FLOAT64,
  p90            FLOAT64,
  p99            FLOAT64
)
PARTITION BY DATE(ts)
CLUSTER BY model_version, split;
 
-- ----------------------------------------------------------------------------
-- 2. feature_drift
-- ----------------------------------------------------------------------------
-- Per-feature stats over time. One row per (run, model_version, split,
-- issue_month, feature). Numeric and categorical features share the same
-- table; irrelevant columns are NULL depending on feature_type.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `project-01523b1d-fc19-4c00-97e.creditrisk.feature_drift` (
  ts                 TIMESTAMP NOT NULL,
  model_version      STRING,
  split              STRING,
  issue_month        STRING,
  feature_name       STRING    NOT NULL,
  feature_type       STRING    NOT NULL,    -- 'numeric' or 'categorical'
  n                  INT64,
  null_rate          FLOAT64,
 
  -- numeric stats (NULL for categorical features)
  mean               FLOAT64,
  std                FLOAT64,
  min                FLOAT64,
  max                FLOAT64,
 
  -- categorical stats (NULL for numeric features)
  top_category       STRING,
  top_category_share FLOAT64,
  entropy            FLOAT64
)
PARTITION BY DATE(ts)
CLUSTER BY model_version, split, feature_name;
 
-- ----------------------------------------------------------------------------
-- 3. monitoring_rollups
-- ----------------------------------------------------------------------------
-- Per-run ranking-performance rollups: Lift@K and Recall@K for K in {1, 5, 10}.
-- Operationally, this is the "is the model still useful for prioritization"
-- table.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_rollups` (
  ts                  TIMESTAMP NOT NULL,
  model_version       STRING,
  split               STRING,
  n                   INT64,
  base_rate           FLOAT64,
 
  top_1pct_default_rate   FLOAT64,
  top_5pct_default_rate   FLOAT64,
  top_10pct_default_rate  FLOAT64,
 
  lift_at_1pct        FLOAT64,
  lift_at_5pct        FLOAT64,
  lift_at_10pct       FLOAT64,
 
  recall_at_1pct      FLOAT64,
  recall_at_5pct      FLOAT64,
  recall_at_10pct     FLOAT64
)
PARTITION BY DATE(ts)
CLUSTER BY model_version, split;
 
-- ----------------------------------------------------------------------------
-- 4. monitoring_alerts
-- ----------------------------------------------------------------------------
-- Threshold-based alerts written by the alert SQL files in sql/monitoring/.
-- Each row is one alert event: an observation that crossed a threshold.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_alerts` (
  ts              TIMESTAMP NOT NULL,
  alert_type      STRING    NOT NULL,   -- e.g. 'score_p90_drift', 'numeric_mean_drift', 'categorical_share_drift'
  severity        STRING,                -- 'info' | 'warn' | 'critical'
  model_version   STRING,
  split           STRING,
  issue_month     STRING,
  feature_name    STRING,                -- NULL for score-level alerts
  observed_value  FLOAT64,
  threshold_value FLOAT64,
  message         STRING                 -- short human-readable description
)
PARTITION BY DATE(ts)
CLUSTER BY alert_type, severity;
 
 
-- ============================================================================
-- *_latest views
--
-- Each view returns rows from the corresponding base table, but only for
-- the most recent run per (model_version, split). The Looker Studio
-- dashboard queries these views so it always shows current state without
-- needing to filter on `ts` manually.
-- ============================================================================
 
-- ----------------------------------------------------------------------------
-- score_drift_latest
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.score_drift_latest` AS
WITH latest AS (
  SELECT model_version, split, MAX(ts) AS max_ts
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.score_drift`
  GROUP BY model_version, split
)
SELECT s.*
FROM `project-01523b1d-fc19-4c00-97e.creditrisk.score_drift` s
JOIN latest l
  ON s.model_version = l.model_version
 AND s.split         = l.split
 AND s.ts            = l.max_ts;
 
-- ----------------------------------------------------------------------------
-- feature_drift_latest
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.feature_drift_latest` AS
WITH latest AS (
  SELECT model_version, split, MAX(ts) AS max_ts
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.feature_drift`
  GROUP BY model_version, split
)
SELECT f.*
FROM `project-01523b1d-fc19-4c00-97e.creditrisk.feature_drift` f
JOIN latest l
  ON f.model_version = l.model_version
 AND f.split         = l.split
 AND f.ts            = l.max_ts;
 
-- ----------------------------------------------------------------------------
-- monitoring_rollups_latest
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_rollups_latest` AS
WITH latest AS (
  SELECT model_version, split, MAX(ts) AS max_ts
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_rollups`
  GROUP BY model_version, split
)
SELECT r.*
FROM `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_rollups` r
JOIN latest l
  ON r.model_version = l.model_version
 AND r.split         = l.split
 AND r.ts            = l.max_ts;
 
-- ----------------------------------------------------------------------------
-- monitoring_alerts_latest
-- ----------------------------------------------------------------------------
-- For alerts, "latest" means the most recent run per alert_type. Older
-- alerts remain in the base table for audit; this view shows current state.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_alerts_latest` AS
WITH latest AS (
  SELECT alert_type, MAX(ts) AS max_ts
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_alerts`
  GROUP BY alert_type
)
SELECT a.*
FROM `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_alerts` a
JOIN latest l
  ON a.alert_type = l.alert_type
 AND a.ts         = l.max_ts;