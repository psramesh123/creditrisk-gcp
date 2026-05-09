DECLARE mv STRING DEFAULT (
  SELECT model_version
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.predictions`
  ORDER BY ts DESC
  LIMIT 1
);







INSERT INTO `project-01523b1d-fc19-4c00-97e.creditrisk.feature_drift`
WITH cohort AS (
  -- Define the cohort using predictions (what you actually scored)
  SELECT DISTINCT
    p.model_version,
    p.split,
    p.loan_id,
    p.issue_date,
    FORMAT_DATE('%Y-%m', p.issue_date) AS issue_month
  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.predictions` p
  WHERE p.model_version = mv
    AND p.split IN ('valid','test')
),
base AS (
  -- Bring in feature values from features table
  SELECT
    c.model_version,
    c.split,
    c.issue_month,
    f.loan_id,
    f.issue_date,

    -- numeric
    f.loan_amount,
    f.interest_rate,
    f.annual_income,
    f.dti,
    f.revol_bal,
    f.revol_util,
    f.total_acc,

    -- categorical
    f.home_ownership,
    f.grade,
    f.purpose,
    f.verification_status,
    f.initial_list_status
  FROM cohort c
  JOIN `project-01523b1d-fc19-4c00-97e.creditrisk.features` f
  USING (loan_id, issue_date)
),
-- -------------------------
-- NUMERIC FEATURES (unpivot long)
-- -------------------------
num_long AS (
  SELECT model_version, split, issue_month, loan_id,
         feature_name, feature_value
  FROM base
  UNPIVOT(feature_value FOR feature_name IN (
    loan_amount,
    interest_rate,
    annual_income,
    dti,
    revol_bal,
    revol_util,
    total_acc
  ))
),
num_stats AS (
  SELECT
    CURRENT_TIMESTAMP() AS ts,
    model_version,
    split,
    issue_month,
    feature_name,
    'numeric' AS feature_type,
    COUNT(*) AS n,
    AVG(CASE WHEN feature_value IS NULL THEN 1 ELSE 0 END) AS null_rate,
    AVG(feature_value) AS mean,
    STDDEV_SAMP(feature_value) AS std,
    MIN(feature_value) AS min,
    MAX(feature_value) AS max,
    CAST(NULL AS STRING) AS top_category,
    CAST(NULL AS FLOAT64) AS top_category_share,
    CAST(NULL AS FLOAT64) AS entropy
  FROM num_long
  GROUP BY model_version, split, issue_month, feature_name
),
-- -------------------------
-- CATEGORICAL FEATURES (unpivot long)
-- -------------------------
cat_long AS (
  SELECT model_version, split, issue_month, loan_id,
         feature_name, feature_value
  FROM base
  UNPIVOT(feature_value FOR feature_name IN (
    home_ownership,
    grade,
    purpose,
    verification_status,
    initial_list_status
  ))
),
cat_counts AS (
  SELECT
    model_version, split, issue_month, feature_name,
    feature_value,
    COUNT(*) AS cnt
  FROM cat_long
  GROUP BY model_version, split, issue_month, feature_name, feature_value
),
cat_totals AS (
  SELECT
    model_version, split, issue_month, feature_name,
    SUM(cnt) AS n
  FROM cat_counts
  GROUP BY model_version, split, issue_month, feature_name
),
cat_top AS (
  SELECT
    c.model_version, c.split, c.issue_month, c.feature_name,
    ANY_VALUE(c.feature_value) AS top_category,
    MAX(c.cnt) AS top_cnt
  FROM cat_counts c
  GROUP BY c.model_version, c.split, c.issue_month, c.feature_name
),
cat_entropy AS (
  -- Shannon entropy = -sum(p * ln p), ignoring nulls is OK (tracked separately via null_rate)
  SELECT
    c.model_version, c.split, c.issue_month, c.feature_name,
    -SUM( (c.cnt / t.n) * LN(c.cnt / t.n) ) AS entropy
  FROM cat_counts c
  JOIN cat_totals t
    USING (model_version, split, issue_month, feature_name)
  WHERE c.feature_value IS NOT NULL
  GROUP BY c.model_version, c.split, c.issue_month, c.feature_name
),
cat_nulls AS (
  SELECT
    model_version, split, issue_month, feature_name,
    AVG(CASE WHEN feature_value IS NULL THEN 1 ELSE 0 END) AS null_rate
  FROM cat_long
  GROUP BY model_version, split, issue_month, feature_name
),
cat_stats AS (
  SELECT
    CURRENT_TIMESTAMP() AS ts,
    t.model_version,
    t.split,
    t.issue_month,
    t.feature_name,
    'categorical' AS feature_type,
    t.n AS n,
    n.null_rate AS null_rate,

    CAST(NULL AS FLOAT64) AS mean,
    CAST(NULL AS FLOAT64) AS std,
    CAST(NULL AS FLOAT64) AS min,
    CAST(NULL AS FLOAT64) AS max,

    top.top_category AS top_category,
    SAFE_DIVIDE(top.top_cnt, t.n) AS top_category_share,
    e.entropy AS entropy
  FROM cat_totals t
  JOIN cat_top top
    USING (model_version, split, issue_month, feature_name)
  LEFT JOIN cat_entropy e
    USING (model_version, split, issue_month, feature_name)
  LEFT JOIN cat_nulls n
    USING (model_version, split, issue_month, feature_name)
)
SELECT * FROM num_stats
UNION ALL
SELECT * FROM cat_stats;
