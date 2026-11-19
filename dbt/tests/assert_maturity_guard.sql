-- Fails if any loan was issued after 2017-12-01: such loans may not
-- have had time to repay or default by the data snapshot.
select loan_id, issue_date
from {{ ref('features') }}
where issue_date > date('2017-12-01')
