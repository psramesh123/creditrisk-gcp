"""
Synthetic end-to-end test for src/explain/reason_codes.py.

Builds a model exactly the way train.py does (one-hot + passthrough ->
XGBoost with early stopping -> isotonic calibration via FrozenEstimator),
on fake loans whose risk drivers are known, then checks that:
  * SHAP contributions add up to the model margin,
  * every declined applicant gets at least one reportable reason,
  * Lending Club's own grade/rate never appear as a reason,
  * the planted risk drivers come out on top,
  * effects run in the expected direction.

Run:  python tests/test_reason_codes.py
"""

import os
import sys

import numpy as np
import pandas as pd
from sklearn.calibration import CalibratedClassifierCV
from sklearn.compose import ColumnTransformer
from sklearn.frozen import FrozenEstimator
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder
from xgboost import XGBClassifier

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src", "explain"))
import reason_codes as rc  # noqa: E402

NUM_COLS = ["loan_amount", "interest_rate", "installment", "term_months", "annual_income",
            "dti", "fico_low", "fico_high", "open_acc", "total_acc", "pub_rec",
            "delinq_2yrs", "inq_last_6mths", "revol_bal", "revol_util", "credit_history_years"]
CAT_COLS = ["home_ownership", "grade", "purpose", "verification_status",
            "initial_list_status", "emp_length"]


def fake_loans(n, seed):
    r = np.random.default_rng(seed)
    fico = r.normal(700, 30, n).clip(620, 850).round()
    dti = r.gamma(4, 4.5, n).clip(0, 60)
    inc = np.exp(r.normal(11, 0.5, n))
    amt = r.uniform(1000, 40000, n).round(-2)
    term = r.choice([36, 60], n, p=[0.75, 0.25])
    inq = r.poisson(0.8, n)
    util = r.uniform(0, 100, n)
    logit = (-1.2 - 0.025 * (fico - 700) + 0.04 * (dti - 18) + 0.35 * (term == 60)
             + 0.25 * inq + 0.01 * (util - 50) + 0.4 * (amt / inc - 0.2))
    y = (r.random(n) < 1 / (1 + np.exp(-logit))).astype(int)
    grade = pd.cut(-logit, 7, labels=list("GFEDCBA")).astype(str)
    df = pd.DataFrame({
        "loan_id": [f"L{seed}_{i}" for i in range(n)],
        "issue_date": pd.Timestamp("2016-01-01"),
        "label": y,
        "loan_amount": amt, "interest_rate": 6 + 2.5 * (-logit + 3),
        "installment": amt / term * 1.1, "term_months": term,
        "annual_income": inc, "dti": dti, "fico_low": fico, "fico_high": fico + 4,
        "open_acc": r.poisson(11, n), "total_acc": r.poisson(24, n),
        "pub_rec": r.poisson(0.2, n), "delinq_2yrs": r.poisson(0.3, n),
        "inq_last_6mths": inq, "revol_bal": r.gamma(2, 8000, n),
        "revol_util": util, "credit_history_years": r.uniform(2, 30, n).round(),
        "home_ownership": r.choice(["RENT", "MORTGAGE", "OWN"], n),
        "grade": grade,
        "purpose": r.choice(["debt_consolidation", "credit_card", "other"], n),
        "verification_status": r.choice(["Verified", "Not Verified", "Source Verified"], n),
        "initial_list_status": r.choice(["w", "f"], n),
        "emp_length": r.choice(["< 1 year", "5 years", "10+ years", None], n),
    })
    return df


def build_like_train_py(train, valid, num_cols, cat_cols):
    pre = ColumnTransformer([("cat", OneHotEncoder(handle_unknown="ignore"), cat_cols),
                             ("num", "passthrough", num_cols)], remainder="drop")
    clf = XGBClassifier(n_estimators=400, max_depth=4, learning_rate=0.05,
                        early_stopping_rounds=30, eval_metric="logloss",
                        tree_method="hist", n_jobs=-1)
    Xtr = pre.fit_transform(train[num_cols + cat_cols])
    Xva = pre.transform(valid[num_cols + cat_cols])
    clf.fit(Xtr, train["label"], eval_set=[(Xva, valid["label"])], verbose=False)
    pipe = Pipeline([("pre", pre), ("clf", clf)])
    cal = CalibratedClassifierCV(estimator=FrozenEstimator(pipe), method="isotonic", cv=None)
    cal.fit(valid[num_cols + cat_cols], valid["label"])
    return {"model": cal, "model_version": "synthetic", "num_cols": num_cols, "cat_cols": cat_cols}


DROP = {
    "full": set(),
    "no_lc": {"grade", "interest_rate"},
    "no_lc_strict": {"grade", "interest_rate", "installment"},
}


def check(feature_set):
    num = [c for c in NUM_COLS if c not in DROP[feature_set]]
    cat = [c for c in CAT_COLS if c not in DROP[feature_set]]
    art = build_like_train_py(fake_loans(20000, 1), fake_loans(5000, 2), num, cat)
    out, s = rc.run(art, fake_loans(5000, 3))

    assert s["additivity_max_error"] < 1e-3, s["additivity_max_error"]
    codes = set(out.filter(like="_code").stack().dropna())
    assert codes <= {v[0] for v in rc.REASON_TEXT.values()}  # grade/rate never reported

    # Term is reported as a note, never as one of the reasons.
    assert "R10" not in codes
    assert "term_note" in out.columns
    if feature_set == "no_lc_strict":
        # No term-dependent feature, so applicants can be re-scored at 36 months.
        assert "qualifies_at_36m" in out.columns
        assert not out.loc[out["term_months"] == 36, "qualifies_at_36m"].any()
        assert (out.loc[out["qualifies_at_36m"], "p_default_36m"] <= s["pd_cutoff"]).all()  # both rounded to 4 dp
    else:
        assert "qualifies_at_36m" not in out.columns

    if feature_set == "full":
        # The grade absorbs explanation that should belong to applicant facts.
        assert s["nonreportable_share_of_explanation"] > 0.1
    else:
        assert s["nonreportable_share_of_explanation"] < 0.1
        assert s["share_declined_with_no_reportable_reason"] < 0.01
        top = max(s["reason_1_frequency"], key=s["reason_1_frequency"].get)
        assert top in {"R01", "R02", "R03", "R05"}, top  # a planted credit driver
        for f in ["fico_low", "dti", "inq_last_6mths"]:
            assert s["direction_check"][f]["consistent"], (f, s["direction_check"][f])

    print(f"\n[{feature_set}] declined {s['declined']} of {s['rows_scored']}, "
          f"default rate among declined {s['declined_default_rate']}")
    print(f"  additivity max error      {s['additivity_max_error']:.2e}")
    print(f"  non-reportable share      {s['nonreportable_share_of_explanation']}")
    print(f"  mean reasons per decline  {s['mean_reasons_per_decline']}")
    print(f"  reason_1 frequency        {s['reason_1_frequency']}")
    print(f"  term                      {s['term']}")
    print("  sample:")
    cols = ["loan_id", "p_default", "reason_1_text", "reason_1_logodds",
            "reason_2_text", "reason_3_text"]
    print(out[cols].head(3).to_string(index=False))


if __name__ == "__main__":
    os.environ.setdefault("DECLINE_RATE", "0.10")
    check("full")
    check("no_lc")
    check("no_lc_strict")
    print("\nAll checks passed.")
