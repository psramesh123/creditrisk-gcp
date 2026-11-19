-- Mart: model-ready features with an out-of-time split.
-- Earliest 80% of loans by issue date = train, next 10% = valid, latest 10% = test.

with loans as (
    select * from {{ ref('int_loans_clean') }}
),

cutoffs as (
    select
        approx_quantiles(issue_date, 100)[offset(80)] as p80_date,
        approx_quantiles(issue_date, 100)[offset(90)] as p90_date
    from loans
)

select
    l.*,
    case
        when l.issue_date < c.p80_date then 'train'
        when l.issue_date < c.p90_date then 'valid'
        else 'test'
    end as split
from loans l
cross join cutoffs c
