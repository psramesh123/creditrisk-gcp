-- ----------------------------------------------------------------------------
-- model_metrics_latest
-- ----------------------------------------------------------------------------
-- Most recent evaluation row per (model_version, split) from model_metrics,
-- mirroring the other *_latest views in 03_monitoring_tables.sql. The Power BI
-- Executive Summary reads ROC-AUC and Brier from this view.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `project-01523b1d-fc19-4c00-97e.creditrisk.model_metrics_latest` AS
WITH latest AS (
  SELECT model_version, split, MAX(ts) AS max_ts
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.model_metrics`
  GROUP BY model_version, split
)
SELECT m.* EXCEPT (metrics_json)
FROM `project-01523b1d-fc19-4c00-97e.creditrisk.model_metrics` m
JOIN latest l
  ON m.model_version = l.model_version
 AND m.split         = l.split
 AND m.ts            = l.max_ts;
