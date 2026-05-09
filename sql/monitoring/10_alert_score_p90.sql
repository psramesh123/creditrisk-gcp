-- Alerts for SCORE DRIFT: month-to-month p90 changes
-- Creates WARN when abs(p90_delta) >= 0.03, CRITICAL when >= 0.05
DECLARE mv STRING DEFAULT (
  SELECT model_version
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.score_drift`
  ORDER BY ts DESC
  LIMIT 1
);

INSERT INTO `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_alerts`
WITH latest AS (
  SELECT * EXCEPT(rn)
  FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (
             PARTITION BY model_version, split, issue_month
             ORDER BY ts DESC
           ) AS rn
    FROM `project-01523b1d-fc19-4c00-97e.creditrisk.score_drift` s
    WHERE s.model_version = mv
      AND s.split IN ('valid','test')
  )
  WHERE rn = 1
),
deltas AS (
  SELECT
    model_version,
    split,
    issue_month,
    ABS(p90 - LAG(p90) OVER (PARTITION BY model_version, split ORDER BY issue_month)) AS abs_p90_delta,
    p90,
    LAG(p90) OVER (PARTITION BY model_version, split ORDER BY issue_month) AS prev_p90
  FROM latest
)
SELECT
  CURRENT_TIMESTAMP() AS ts,
  model_version,
  split,
  issue_month,
  'score_drift_p90' AS alert_type,
  'p90' AS entity,
  abs_p90_delta AS value,
  CASE WHEN abs_p90_delta >= 0.05 THEN 0.05 ELSE 0.03 END AS threshold,
  CASE
    WHEN abs_p90_delta >= 0.05 THEN 'CRITICAL'
    WHEN abs_p90_delta >= 0.03 THEN 'WARN'
    ELSE 'INFO'
  END AS severity,
  CONCAT('p90 moved from ', CAST(prev_p90 AS STRING), ' to ', CAST(p90 AS STRING)) AS details
FROM deltas
WHERE abs_p90_delta IS NOT NULL
  AND abs_p90_delta >= 0.03;
