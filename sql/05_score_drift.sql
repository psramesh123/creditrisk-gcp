MERGE `project-01523b1d-fc19-4c00-97e.creditrisk.score_drift` T
USING (
  -- Step 1: identify the most recent scoring run for each (model_version, split).
  -- The dashboard always wants drift computed off the freshest predictions.
  WITH latest_run AS (
    SELECT model_version, split, MAX(ts) AS max_ts
    FROM `project-01523b1d-fc19-4c00-97e.creditrisk.predictions`
    GROUP BY model_version, split
  ),
 
  -- Step 2: pull just the predictions from those latest runs.
  latest_predictions AS (
    SELECT
      p.ts,
      p.model_version,
      p.split,
      p.issue_date,
      p.p_default
    FROM `project-01523b1d-fc19-4c00-97e.creditrisk.predictions` p
    JOIN latest_run l
      ON p.model_version = l.model_version
     AND p.split         = l.split
     AND p.ts            = l.max_ts
    WHERE p.issue_date IS NOT NULL
      AND p.p_default  IS NOT NULL
  ),
 
  -- Step 3: aggregate to (model_version, split, issue_month).
  -- Stamp every output row with a single CURRENT_TIMESTAMP() so the whole
  -- snapshot shares one ts (matches the assumption in the _latest view).
  monthly_drift AS (
    SELECT
      CURRENT_TIMESTAMP() AS ts,
      model_version,
      split,
      FORMAT_DATE('%Y-%m', issue_date) AS issue_month,
      COUNT(*)                              AS n,
      AVG(p_default)                        AS avg_pd,
      APPROX_QUANTILES(p_default, 100)[OFFSET(50)] AS p50,
      APPROX_QUANTILES(p_default, 100)[OFFSET(90)] AS p90,
      APPROX_QUANTILES(p_default, 100)[OFFSET(99)] AS p99
    FROM latest_predictions
    GROUP BY model_version, split, issue_month
  )
 
  SELECT * FROM monthly_drift
) S
ON  T.model_version = S.model_version
AND T.split         = S.split
AND T.issue_month   = S.issue_month
 
-- Existing row for this (model_version, split, issue_month): refresh it.
WHEN MATCHED THEN UPDATE SET
  ts      = S.ts,
  n       = S.n,
  avg_pd  = S.avg_pd,
  p50     = S.p50,
  p90     = S.p90,
  p99     = S.p99
 
-- New (model_version, split, issue_month) combination: insert it.
WHEN NOT MATCHED BY TARGET THEN
  INSERT (ts, model_version, split, issue_month, n, avg_pd, p50, p90, p99)
  VALUES (S.ts, S.model_version, S.split, S.issue_month, S.n, S.avg_pd, S.p50, S.p90, S.p99);
 