-- Alerts for NUMERIC FEATURE DRIFT: month-to-month mean changes (relative)
-- WARN when rel_mean_delta >= 0.10, CRITICAL when >= 0.20
DECLARE mv STRING DEFAULT (
  SELECT model_version
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.feature_drift`
  ORDER BY ts DESC
  LIMIT 1
);

INSERT INTO `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_alerts`
WITH latest AS (
  SELECT * EXCEPT(rn)
  FROM (
    SELECT d.*,
           ROW_NUMBER() OVER (
             PARTITION BY model_version, split, issue_month, feature_name
             ORDER BY ts DESC
           ) AS rn
    FROM `project-01523b1d-fc19-4c00-97e.creditrisk.feature_drift` d
    WHERE d.model_version = mv
      AND d.split IN ('valid','test')
      AND d.feature_type = 'numeric'
  )
  WHERE rn = 1
),
deltas AS (
  SELECT
    model_version,
    split,
    issue_month,
    feature_name,
    mean,
    LAG(mean) OVER (PARTITION BY model_version, split, feature_name ORDER BY issue_month) AS prev_mean,
    ABS(mean - LAG(mean) OVER (PARTITION BY model_version, split, feature_name ORDER BY issue_month)) AS abs_mean_delta,
    SAFE_DIVIDE(
      ABS(mean - LAG(mean) OVER (PARTITION BY model_version, split, feature_name ORDER BY issue_month)),
      NULLIF(ABS(LAG(mean) OVER (PARTITION BY model_version, split, feature_name ORDER BY issue_month)), 0)
    ) AS rel_mean_delta
  FROM latest
)
SELECT
  CURRENT_TIMESTAMP() AS ts,
  model_version,
  split,
  issue_month,
  'numeric_mean_drift' AS alert_type,
  feature_name AS entity,
  rel_mean_delta AS value,
  CASE WHEN rel_mean_delta >= 0.20 THEN 0.20 ELSE 0.10 END AS threshold,
  CASE
    WHEN rel_mean_delta >= 0.20 THEN 'CRITICAL'
    WHEN rel_mean_delta >= 0.10 THEN 'WARN'
    ELSE 'INFO'
  END AS severity,
  CONCAT(
    'mean moved from ', CAST(prev_mean AS STRING),
    ' to ', CAST(mean AS STRING),
    ' (abs_delta=', CAST(abs_mean_delta AS STRING), ')'
  ) AS details
FROM deltas
WHERE prev_mean IS NOT NULL
  AND rel_mean_delta IS NOT NULL
  AND rel_mean_delta >= 0.10;
