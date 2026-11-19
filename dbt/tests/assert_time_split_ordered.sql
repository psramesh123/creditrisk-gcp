-- Fails if any train loan is issued on or after the first valid loan,
-- or any valid loan on or after the first test loan.
with bounds as (
    select split, min(issue_date) as first_date, max(issue_date) as last_date
    from {{ ref('features') }}
    group by split
)
select earlier.split as earlier_split, later.split as later_split,
       earlier.last_date, later.first_date
from bounds earlier
join bounds later
  on (earlier.split = 'train' and later.split = 'valid')
  or (earlier.split = 'valid' and later.split = 'test')
where earlier.last_date >= later.first_date
