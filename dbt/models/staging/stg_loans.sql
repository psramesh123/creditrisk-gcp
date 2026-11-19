-- Staging: one row per raw record, with typed and renamed columns.
-- No filtering or business logic here; that happens in intermediate models.

with source as (
    select * from {{ source('creditrisk', 'loans_raw') }}
)

select
    -- identifiers and dates
    safe_cast(id as string)                         as loan_id,
    safe.parse_date('%b-%Y', issue_d)               as issue_date,
    loan_status,

    -- loan terms
    safe_cast(loan_amnt as float64)                 as loan_amount,
    safe_cast(int_rate as float64)                  as interest_rate,
    safe_cast(installment as float64)               as installment,
    safe_cast(regexp_extract(term, r'(\d+)') as int64) as term_months,

    -- borrower attributes
    safe_cast(annual_inc as float64)                as annual_income,
    safe_cast(dti as float64)                       as dti,
    emp_length,
    home_ownership,
    verification_status,
    purpose,

    -- credit bureau
    safe_cast(fico_range_low as float64)            as fico_low,
    safe_cast(fico_range_high as float64)           as fico_high,
    safe_cast(open_acc as float64)                  as open_acc,
    safe_cast(total_acc as float64)                 as total_acc,
    safe_cast(pub_rec as float64)                   as pub_rec,
    safe.parse_date('%b-%Y', earliest_cr_line)      as earliest_cr_line_date,
    safe_cast(delinq_2yrs as float64)               as delinq_2yrs,
    safe_cast(inq_last_6mths as float64)            as inq_last_6mths,
    safe_cast(revol_bal as float64)                 as revol_bal,
    safe_cast(revol_util as float64)                as revol_util,

    -- Lending Club's own assessment and listing
    grade,
    initial_list_status

from source
