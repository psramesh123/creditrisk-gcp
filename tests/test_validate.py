"""
Tests for src/train/validate.py: clean data passes, and each kind of
breakage it is meant to catch makes it fail.

Run:  python tests/test_validate.py
"""

import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src", "train"))
from validate import validate_splits  # noqa: E402

NUM = ["loan_amount", "term_months", "annual_income", "dti", "fico_low", "fico_high",
       "revol_util", "inq_last_6mths", "credit_history_years"]
CAT = ["home_ownership", "purpose"]


def split(n, start, end, seed, prefix):
    r = np.random.default_rng(seed)
    dates = pd.to_datetime(r.integers(pd.Timestamp(start).value // 10**9,
                                      pd.Timestamp(end).value // 10**9, n), unit="s").normalize()
    fico = r.integers(660, 845, n)
    return pd.DataFrame({
        "loan_id": [f"{prefix}{i}" for i in range(n)],
        "issue_date": dates,
        "label": (r.random(n) < 0.25).astype(int),
        "loan_amount": r.uniform(1000, 35000, n).round(-2),
        "term_months": r.choice([36, 60], n),
        "annual_income": r.uniform(20000, 200000, n),
        "dti": r.uniform(0, 40, n),
        "fico_low": fico, "fico_high": fico + 4,
        "revol_util": r.uniform(0, 100, n),
        "inq_last_6mths": r.integers(0, 5, n),
        "credit_history_years": r.integers(2, 40, n),
        "home_ownership": r.choice(["RENT", "OWN", "MORTGAGE"], n),
        "purpose": r.choice(["credit_card", "debt_consolidation"], n),
    })


def good():
    return {
        "train": split(3000, "2012-01-01", "2015-12-31", 1, "a"),
        "valid": split(800, "2016-01-01", "2016-12-31", 2, "b"),
        "test": split(800, "2017-01-01", "2017-12-01", 3, "c"),
    }


def run(splits):
    return validate_splits(splits, NUM, CAT, limited=True)


def setcol(name, col, value):
    """Return a mutation that replaces one column of one split."""
    def mutate(s):
        df = s[name]
        s[name] = df.assign(**{col: value(df) if callable(value) else value})
    return mutate


def expect_fail(name, mutate, needle):
    s = good()
    mutate(s)
    rep = run(s)
    assert not rep["passed"], f"{name}: expected a failure"
    assert any(needle in f for f in rep["fails"]), f"{name}: {rep['fails']}"
    print(f"  caught: {name:24s} -> {rep['fails'][0]}")


if __name__ == "__main__":
    rep = run(good())
    assert rep["passed"], rep["fails"]
    print(f"clean data passes ({len(rep['warnings'])} warnings)")

    expect_fail("empty train", lambda s: s.update(train=s["train"].iloc[:0]),
                "train split is empty")
    expect_fail("missing column", lambda s: s.update(train=s["train"].drop(columns="dti")),
                "missing columns")
    expect_fail("label not 0/1", setcol("valid", "label", lambda d: d["label"].where(d.index > 5, 2)),
                "other than 0/1")
    expect_fail("overlapping time split",
                setcol("train", "issue_date", lambda d: d["issue_date"] + pd.DateOffset(years=2)),
                "time split broken")
    expect_fail("after maturity guard",
                setcol("test", "issue_date", lambda d: d["issue_date"] + pd.DateOffset(years=1)),
                "maturity guard")
    expect_fail("loan in two splits",
                setcol("test", "loan_id", lambda d: d["loan_id"].str.replace("c", "a")),
                "appear in both")
    expect_fail("duplicate loan_id", setcol("valid", "loan_id", "b0"), "duplicate loan_ids")
    expect_fail("mostly missing feature", setcol("train", "revol_util", np.nan), "missing")
    expect_fail("FICO in wrong units",
                setcol("train", "fico_low", lambda d: d["fico_low"] / 100), "fico_low")
    expect_fail("unexpected term", setcol("train", "term_months", 48), "term_months")

    # Full-size check: too few training rows when not running with BQ_LIMIT
    rep = validate_splits(good(), NUM, CAT, limited=False)
    assert any("rows" in f for f in rep["fails"])
    print("  caught: too few train rows")
    print("\nAll validation checks passed.")
