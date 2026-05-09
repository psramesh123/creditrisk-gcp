MERGE `project-01523b1d-fc19-4c00-97e.creditrisk.monitoring_rollups` T
USING (
  -- Step 1: identify the most recent scoring run for each (model_version, split).
  WITH latest_run AS (
    SELECT model_version, split, MAX(ts) AS max_ts
    FROM `project-01523b1d-fc19-4c00-97e.creditrisk.predictions`
    GROUP BY model_version, split
  ),

  -- Step 2: join latest predictions to features for the ground-truth labels.
  -- Inner join: drops loans that exist in predictions but not in features
  -- (shouldn't happen, but defensive). Loans with NULL labels were already
  -- excluded during feature build, so they won't be present here either.
  scored AS (
    SELECT
      p.model_version,
      p.split,
      p.loan_id,
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
      AND f.label    IS NOT NULL
  ),

  -- Step 3: rank loans within each (model_version, split) by descending
  -- predicted PD, and compute the percentile rank (0.0 = highest risk,
  -- 1.0 = lowest risk). PERCENT_RANK gives values in [0, 1] per partition.
  ranked AS (
    SELECT
      model_version,
      split,
      label,
      PERCENT_RANK() OVER (
        PARTITION BY model_version, split
        ORDER BY p_default DESC
      ) AS pct_rank
    FROM scored
  ),

  -- Step 4: aggregate to one row per (model_version, split).
  -- Top-K means "loans whose pct_rank <= K/100", i.e. the top K% by score.
  -- AVG(IF(...)) gives the count of matching rows divided by total rows
  -- when wrapped in COUNTIF/COUNT, so we use COUNTIF for clarity.
  rollups AS (
    SELECT
      CURRENT_TIMESTAMP() AS ts,
      model_version,
      split,
      COUNT(*)            AS n,
      AVG(label)          AS base_rate,

      -- Top-K default rate: of the top K% loans by score, what fraction defaulted?
      SAFE_DIVIDE(
        COUNTIF(pct_rank <= 0.01 AND label = 1),
        COUNTIF(pct_rank <= 0.01)
      ) AS top_1pct_default_rate,

      SAFE_DIVIDE(
        COUNTIF(pct_rank <= 0.05 AND label = 1),
        COUNTIF(pct_rank <= 0.05)
      ) AS top_5pct_default_rate,

      SAFE_DIVIDE(
        COUNTIF(pct_rank <= 0.10 AND label = 1),
        COUNTIF(pct_rank <= 0.10)
      ) AS top_10pct_default_rate,

      -- Recall@K: of all defaults, what fraction fell in the top K%?
      SAFE_DIVIDE(
        COUNTIF(pct_rank <= 0.01 AND label = 1),
        COUNTIF(label = 1)
      ) AS recall_at_1pct,

      SAFE_DIVIDE(
        COUNTIF(pct_rank <= 0.05 AND label = 1),
        COUNTIF(label = 1)
      ) AS recall_at_5pct,

      SAFE_DIVIDE(
        COUNTIF(pct_rank <= 0.10 AND label = 1),
        COUNTIF(label = 1)
      ) AS recall_at_10pct
    FROM ranked
    GROUP BY model_version, split
  ),

  -- Step 5: derive lift = (top-K default rate) / base_rate.
  -- Done in a separate CTE so the lift expressions can reference the
  -- aggregated columns from rollups by name.
  with_lift AS (
    SELECT
      *,
      SAFE_DIVIDE(top_1pct_default_rate,  base_rate) AS lift_at_1pct,
      SAFE_DIVIDE(top_5pct_default_rate,  base_rate) AS lift_at_5pct,
      SAFE_DIVIDE(top_10pct_default_rate, base_rate) AS lift_at_10pct
    FROM rollups
  )

  SELECT * FROM with_lift
) S
ON  T.model_version = S.model_version
AND T.split         = S.split

-- Existing row for this (model_version, split): refresh it.
WHEN MATCHED THEN UPDATE SET
  ts                     = S.ts,
  n                      = S.n,
  base_rate              = S.base_rate,
  top_1pct_default_rate  = S.top_1pct_default_rate,
  top_5pct_default_rate  = S.top_5pct_default_rate,
  top_10pct_default_rate = S.top_10pct_default_rate,
  lift_at_1pct           = S.lift_at_1pct,
  lift_at_5pct           = S.lift_at_5pct,
  lift_at_10pct          = S.lift_at_10pct,
  recall_at_1pct         = S.recall_at_1pct,
  recall_at_5pct         = S.recall_at_5pct,
  recall_at_10pct        = S.recall_at_10pct

-- New (model_version, split) combination: insert it.
WHEN NOT MATCHED BY TARGET THEN
  INSERT (
    ts, model_version, split, n, base_rate,
    top_1pct_default_rate, top_5pct_default_rate, top_10pct_default_rate,
    lift_at_1pct, lift_at_5pct, lift_at_10pct,
    recall_at_1pct, recall_at_5pct, recall_at_10pct
  )
  VALUES (
    S.ts, S.model_version, S.split, S.n, S.base_rate,
    S.top_1pct_default_rate, S.top_5pct_default_rate, S.top_10pct_default_rate,
    S.lift_at_1pct, S.lift_at_5pct, S.lift_at_10pct,
    S.recall_at_1pct, S.recall_at_5pct, S.recall_at_10pct
  );