"""
Test for src/explain/implied_rate_check.py: the annuity solver recovers the
interest rate from amount, installment and term on loans with known rates.

Run:  python tests/test_implied_rate.py
"""

import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src", "explain"))
import implied_rate_check as ic  # noqa: E402

if __name__ == "__main__":
    r = np.random.default_rng(0)
    n = 5000
    amount = r.uniform(1000, 40000, n).round(-2)
    term = r.choice([36, 60], n)
    rate = r.uniform(5, 31, n).round(2)
    installment = np.round(ic.payment(amount, rate / 1200, term), 2)  # rounded to cents
    df = pd.DataFrame({"loan_amount": amount, "installment": installment,
                       "term_months": term, "interest_rate": rate})
    s = ic.run(df)
    assert s["rows_solved"] == n
    assert s["pearson_implied_vs_actual"] > 0.9999
    assert s["p95_abs_error_pct_points"] < 0.01
    # An installment too small for any positive rate cannot be solved
    assert np.isnan(ic.implied_annual_rate([10000], [100], [36])[0])
    print(f"implied rate recovered: median error {s['median_abs_error_pct_points']} pct points")
    print("All implied-rate checks passed.")
