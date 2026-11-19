-- Intermediate: business rules applied to the staged loans.
--   1. Define the default label from loan_status
--   2. Keep one row per loan
--   3. Drop unusable or immature loans
--   4. Add credit history length

with loans as (
    select * from {{ ref('stg_loans') }}
),

labelled as (
    select
        *,
        case
            when loan_status in ('Charged Off', 'Default',
                                 'Late (31-120 days)', 'Late (16-30 days)') then 1
            when loan_status = 'Fully Paid' then 0
            else null   -- e.g. Current: outcome not known yet
        end as label
    from loans
),

deduped as (
    select * from labelled
    qualify row_number() over (partition by loan_id order by issue_date) = 1
)

select
    * except (loan_status, earliest_cr_line_date),
    date_diff(issue_date, earliest_cr_line_date, year) as credit_history_years
from deduped
where issue_date is not null
  and label is not null
  and term_months is not null
  and issue_date <= date('2017-12-01')   -- maturity guard
  and annual_income > 0
  and dti between 0 and 100
