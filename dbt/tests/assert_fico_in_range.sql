-- Fails if any FICO score is outside 300-850, which would point to a
-- parsing or unit error upstream.
select loan_id, fico_low, fico_high
from {{ ref('features') }}
where fico_low not between 300 and 850
   or fico_high not between 300 and 850
