CREATE OR REPLACE TABLE `project-01523b1d-fc19-4c00-97e.creditrisk.features` AS
WITH base AS (
  SELECT
    SAFE_CAST(id AS STRING) AS loan_id,
    SAFE.PARSE_DATE('%b-%Y', issue_d) AS issue_date,
    CASE
      WHEN loan_status IN ('Charged Off', 'Default', 'Late (31-120 days)', 'Late (16-30 days)')
        THEN 1
      WHEN loan_status = 'Fully Paid'
        THEN 0
      ELSE NULL
    END AS label,
    
    --- loan terms ---
    SAFE_CAST(loan_amnt AS FLOAT64) AS loan_amount,
    SAFE_CAST(int_rate AS FLOAT64) AS interest_rate,
    SAFE_CAST(installment as FLOAT64) AS installment,
    SAFE_CAST(REGEXP_EXTRACT(term, r'(\d+)') AS INT64) AS term_months,

    --- borrower attributes ---
    SAFE_CAST(annual_inc AS FLOAT64) AS annual_income,
    SAFE_CAST(dti AS FLOAT64) AS dti,
    SAFE_CAST(emp_length AS STRING) AS emp_length,


    --- credit bureau: FICO ---
    SAFE_CAST(fico_range_low AS FLOAT64) AS fico_low,
    SAFE_CAST(fico_range_high AS FLOAT64) AS fico_high,

    --- credit bureau: history & accounts ---
    SAFE_CAST(open_acc        AS FLOAT64) AS open_acc,
    SAFE_CAST(total_acc       AS FLOAT64) AS total_acc,
    SAFE_CAST(pub_rec         AS FLOAT64) AS pub_rec,
    SAFE.PARSE_DATE('%b-%Y', earliest_cr_line) AS earliest_cr_line_date,

    --- credit bureau: delinquency & inquiries ---
    SAFE_CAST(delinq_2yrs    AS FLOAT64) AS delinq_2yrs,
    SAFE_CAST(inq_last_6mths AS FLOAT64) AS inq_last_6mths,

    --- credit bureau: utilisation & factors ---
    SAFE_CAST(revol_bal  AS FLOAT64) AS revol_bal,
    SAFE_CAST(revol_util AS FLOAT64) AS revol_util,

    --- categorical features ---
    SAFE_CAST(home_ownership AS STRING) AS home_ownership,
    SAFE_CAST(grade AS STRING) AS grade,
    SAFE_CAST(purpose AS STRING) AS purpose,
    SAFE_CAST(verification_status AS STRING) AS verification_status,
    SAFE_CAST(initial_list_status AS STRING) AS initial_list_status,

  FROM `project-01523b1d-fc19-4c00-97e.creditrisk.loans_raw`
),

dedup AS (
  -- keep one row per loan_id
  SELECT * FROM base
  QUALIFY ROW_NUMBER() OVER (PARTITION BY loan_id ORDER BY issue_date) = 1
),

clean AS (
  SELECT 
  *,
  DATE_DIFF(issue_date, earliest_cr_line_date, YEAR) AS credit_history_years
  FROM dedup
  WHERE issue_date IS NOT NULL
    AND label IS NOT NULL
    AND term_months IS NOT NULL
    AND issue_date <= DATE('2017-12-01') -- Maturity guard: drop loans issued after 2017-12-01 to ensure 60-month 
    -- terms have ~7+ years to mature by data snapshot date
    AND annual_income > 0
    AND dti BETWEEN 0 AND 100
),

cutoffs AS (
  SELECT
    APPROX_QUANTILES(issue_date, 100)[OFFSET(80)] AS p80_date,
    APPROX_QUANTILES(issue_date, 100)[OFFSET(90)] AS p90_date
  FROM clean
),

splits AS (
  SELECT
    c.*,
    CASE
      WHEN issue_date < k.p80_date THEN 'train'
      WHEN issue_date < k.p90_date THEN 'valid'
      ELSE 'test'
    END AS split
  FROM clean c
  CROSS JOIN cutoffs k
)
SELECT * FROM splits;

