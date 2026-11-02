"""
Can the interest rate be recovered from loan_amount, installment and term?

A fixed-rate loan's monthly payment follows the annuity formula

    installment = amount * r / (1 - (1 + r) ** -n)

where r is the monthly rate and n the number of months. Payment rises
strictly with r, so given amount, installment and n there is exactly one r.
This script solves for it on every loan and compares it with Lending Club's
interest_rate. A correlation near 1 means a model that sees amount,
installment and term effectively sees the interest rate, and through it the
grade, even when grade and interest_rate are removed.

Usage
    SCORE_SPLIT=test python src/explain/implied_rate_check.py
    INPUT_CSV=loans.csv python src/explain/implied_rate_check.py   # offline
"""

import json
import os

import numpy as np
import pandas as pd

PROJECT_ID = os.environ.get("PROJECT_ID", "project-01523b1d-fc19-4c00-97e")
BQ_DATASET = os.environ.get("BQ_DATASET", "creditrisk")
FEATURES_TABLE = os.environ.get("FEATURES_TABLE", f"{PROJECT_ID}.{BQ_DATASET}.features")
SPLIT = os.environ.get("SCORE_SPLIT", "test")
INPUT_CSV = os.environ.get("INPUT_CSV")
OUT_DIR = os.environ.get("OUT_DIR", "artifacts/reason_codes")


def payment(amount, r, n):
    return amount * r / (1.0 - (1.0 + r) ** (-n))


def implied_annual_rate(amount, installment, n, iters=80):
    """Annual rate in percent, solved by bisection on the monthly rate.

    Returns NaN where no positive rate fits (installment <= amount / n) or an
    input is missing.
    """
    amount = np.asarray(amount, float)
    installment = np.asarray(installment, float)
    n = np.asarray(n, float)

    lo = np.full(amount.shape, 1e-9)
    hi = np.full(amount.shape, 0.20)  # 20% a month is far above any real loan
    for _ in range(iters):
        mid = (lo + hi) / 2
        too_high = payment(amount, mid, n) > installment
        hi = np.where(too_high, mid, hi)
        lo = np.where(too_high, lo, mid)

    rate = (lo + hi) / 2 * 12 * 100
    valid = (installment > amount / n) & np.isfinite(amount + installment + n) & (n > 0)
    return np.where(valid, rate, np.nan)


def load_rows() -> pd.DataFrame:
    cols = ["loan_amount", "installment", "term_months", "interest_rate", "grade"]
    if INPUT_CSV:
        df = pd.read_csv(INPUT_CSV)
        return df[df["split"] == SPLIT] if "split" in df.columns else df
    from google.cloud import bigquery

    client = bigquery.Client(project=PROJECT_ID)
    q = f"SELECT {', '.join(cols)} FROM `{FEATURES_TABLE}` WHERE split = @split"
    cfg = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("split", "STRING", SPLIT)]
    )
    return client.query(q, job_config=cfg).to_dataframe()


def run(df: pd.DataFrame) -> dict:
    implied = implied_annual_rate(df["loan_amount"], df["installment"], df["term_months"])
    actual = pd.to_numeric(df["interest_rate"], errors="coerce").to_numpy()
    ok = np.isfinite(implied) & np.isfinite(actual)
    err = np.abs(implied[ok] - actual[ok])

    out = {
        "split": SPLIT,
        "rows": int(len(df)),
        "rows_solved": int(ok.sum()),
        "pearson_implied_vs_actual": round(float(np.corrcoef(implied[ok], actual[ok])[0, 1]), 4),
        "median_abs_error_pct_points": round(float(np.median(err)), 4),
        "p95_abs_error_pct_points": round(float(np.quantile(err, 0.95)), 4),
        "share_within_0.1_pct_points": round(float((err <= 0.1).mean()), 4),
    }
    if "grade" in df.columns:
        g = pd.DataFrame({"grade": df["grade"].to_numpy()[ok], "implied": implied[ok]})
        out["mean_implied_rate_by_grade"] = (
            g.groupby("grade")["implied"].mean().round(2).to_dict()
        )
    return out


def main():
    df = load_rows()
    print(f"Loaded {len(df):,} rows from split='{SPLIT}'")
    summary = run(df)
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, f"{SPLIT}_implied_rate_check.json")
    with open(path, "w") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps(summary, indent=2))
    print(f"Wrote {path}")

    r = summary["pearson_implied_vs_actual"]
    if r > 0.95:
        print("\n=> The interest rate is recoverable from amount, installment and term.")
        print("   Rerun the ablation with FEATURE_SET=no_lc_strict.")


if __name__ == "__main__":
    main()
