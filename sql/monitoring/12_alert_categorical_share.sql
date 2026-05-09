-- Alerts for CATEGORICAL FEATURE DRIFT: month-to-month top_category_share changes
-- WARN when abs_share_delta >= 0.05, CRITICAL when >= 0.08
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
      AND d.feature_type = 'categorical'
  )
  WHERE rn = 1
),
deltas AS (
  SELECT
    model_version,
    split,
    issue_month,
    feature_name,
    top_category,
    top_category_share,
    LAG(top_category_share) OVER (PARTITION BY model_version, split, feature_name ORDER BY issue_month) AS prev_share,
    ABS(top_category_share - LAG(top_category_share) OVER (PARTITION BY model_version, split, feature_name ORDER BY issue_month)) AS abs_share_delta,
    LAG(top_category) OVER (PARTITION BY model_version, split, feature_name ORDER BY issue_month) AS prev_top_category
  FROM latest
)
SELECT
  CURRENT_TIMESTAMP() AS ts,
  model_version,
  split,
  issue_month,
  'categorical_share_drift' AS alert_type,
  feature_name AS entity,
  abs_share_delta AS value,
  CASE WHEN abs_share_delta >= 0.08 THEN 0.08 ELSE 0.05 END AS threshold,
  CASE
    WHEN abs_share_delta >= 0.08 THEN 'CRITICAL'
    WHEN abs_share_delta >= 0.05 THEN 'WARN'
    ELSE 'INFO'
  END AS severity,
  CONCAT(
    'top_share moved from ', CAST(prev_share AS STRING),
    ' to ', CAST(top_category_share AS STRING),
    '; top_cat ', COALESCE(prev_top_category,'NULL'),
    ' -> ', COALESCE(top_category,'NULL')
  ) AS details
FROM deltas
WHERE prev_share IS NOT NULL
  AND abs_share_delta >= 0.05;
