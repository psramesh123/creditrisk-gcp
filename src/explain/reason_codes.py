"""
Reason codes for declined applicants.

For every applicant the model would decline, this script explains *why* in
plain language, the way a lender must when it sends an adverse-action notice.

Pipeline
--------
1. Load the trained artifact (calibrated XGBoost pipeline) and a split.
2. Score applicants with the calibrated model and apply the decline rule.
3. Compute exact TreeSHAP contributions with XGBoost's built-in
   `pred_contribs` (log-odds scale, on the base XGBoost model).
4. Fold one-hot columns back into their original feature
   (SHAP values are additive, so summing them is exact).
5. Group related features into reason codes, drop codes that are not about
   the applicant (Lending Club's own grade / rate / listing type), and keep the
   top K reasons that pushed risk UP.
6. Run diagnostics: additivity, coverage, reason frequency, share of the
   explanation that is non-reportable, and a direction sanity check.

Why SHAP on the base model, not the calibrated probability?
Isotonic calibration is a monotone map applied after XGBoost, so it never
changes which applicants are riskier or which way a feature pushes. SHAP on
the XGBoost log-odds is exact and additive; on the calibrated output it would
be neither.

Usage
-----
    ARTIFACT_PATH=artifacts/no_lc/model.joblib SCORE_SPLIT=test \
        python src/explain/reason_codes.py

Environment variables
    ARTIFACT_PATH   model artifact from train.py          (artifacts/model.joblib)
    SCORE_SPLIT     split to explain                       (test)
    INPUT_CSV       read rows from a CSV instead of BigQuery
    PD_CUTOFF       decline if calibrated PD >= this value
    DECLINE_RATE    otherwise, decline the riskiest fraction (0.10)
    TOP_K           reasons per applicant                  (4)
    MIN_LOGODDS     smallest contribution worth reporting  (0.02)
    OUT_DIR         where outputs are written              (artifacts/reason_codes)
    WRITE_BQ        "1" to also write to BigQuery
    REASONS_TABLE   BigQuery table for the reason codes
"""

import json
import os

import joblib
import numpy as np
import pandas as pd
import xgboost as xgb
from scipy.stats import spearmanr
from sklearn.pipeline import Pipeline

try:
    from sklearn.frozen import FrozenEstimator
except ImportError:  # sklearn < 1.6
    FrozenEstimator = None


PROJECT_ID = os.environ.get("PROJECT_ID", "project-01523b1d-fc19-4c00-97e")
BQ_DATASET = os.environ.get("BQ_DATASET", "creditrisk")
FEATURES_TABLE = os.environ.get("FEATURES_TABLE", f"{PROJECT_ID}.{BQ_DATASET}.features")
REASONS_TABLE = os.environ.get("REASONS_TABLE", f"{PROJECT_ID}.{BQ_DATASET}.reason_codes")

ARTIFACT_PATH = os.environ.get("ARTIFACT_PATH", "artifacts/model.joblib")
SPLIT = os.environ.get("SCORE_SPLIT", "test")
INPUT_CSV = os.environ.get("INPUT_CSV")
PD_CUTOFF = os.environ.get("PD_CUTOFF")
DECLINE_RATE = float(os.environ.get("DECLINE_RATE", "0.10"))
TOP_K = int(os.environ.get("TOP_K", "4"))
MIN_LOGODDS = float(os.environ.get("MIN_LOGODDS", "0.02"))
OUT_DIR = os.environ.get("OUT_DIR", "artifacts/reason_codes")
WRITE_BQ = os.environ.get("WRITE_BQ", "0") == "1"


# ---------------------------------------------------------------------------
# Reason-code dictionary
# feature -> group; group -> (code, applicant-facing text)
# ---------------------------------------------------------------------------
FEATURE_GROUP = {
    "fico_low": "credit_score",
    "fico_high": "credit_score",
    "dti": "debt_to_income",
    "annual_income": "loan_vs_income",
    "loan_amount": "loan_vs_income",
    "installment": "loan_vs_income",
    "term_months": "loan_term",
    "revol_util": "revolving_use",
    "revol_bal": "revolving_use",
    "inq_last_6mths": "recent_inquiries",
    "delinq_2yrs": "delinquency",
    "pub_rec": "public_records",
    "credit_history_years": "history_length",
    "open_acc": "account_mix",
    "total_acc": "account_mix",
    "emp_length": "employment_length",
    "home_ownership": "housing",
    "purpose": "loan_purpose",
    "verification_status": "income_verification",
    # Not about the applicant: Lending Club's own assessment or listing choice.
    "grade": "lc_assessment",
    "interest_rate": "lc_assessment",
    "initial_list_status": "listing_type",
}

REASON_TEXT = {
    "credit_score": ("R01", "Credit score is lower than for approved applicants"),
    "debt_to_income": ("R02", "Existing debt payments are high relative to income"),
    "loan_vs_income": ("R03", "Requested loan or monthly payment is high relative to income"),
    "revolving_use": ("R04", "High balances or utilisation on revolving credit"),
    "recent_inquiries": ("R05", "Several recent applications for credit"),
    "delinquency": ("R06", "Recent history of late payments"),
    "public_records": ("R07", "Public record on credit file"),
    "history_length": ("R08", "Limited length of credit history"),
    "account_mix": ("R09", "Number or type of credit accounts"),
    "loan_term": ("R10", "Longer repayment term requested"),
    "employment_length": ("R11", "Length of employment"),
    "income_verification": ("R12", "Income could not be verified"),
    "loan_purpose": ("R13", "Purpose of the loan"),
    "housing": ("R14", "Housing status"),
}

NON_REPORTABLE = {"lc_assessment", "listing_type"}

# Expected direction of each numeric feature's effect on risk (+1 = more risk
# as the value rises). Used only for the sanity check.
EXPECTED_SIGN = {
    "fico_low": -1, "fico_high": -1, "dti": +1, "annual_income": -1,
    "loan_amount": +1, "installment": +1, "revol_util": +1,
    "inq_last_6mths": +1, "delinq_2yrs": +1, "pub_rec": +1,
    "credit_history_years": -1, "term_months": +1,
}


# ---------------------------------------------------------------------------
# Model helpers
# ---------------------------------------------------------------------------
def unwrap_pipeline(model) -> Pipeline:
    """Return the sklearn Pipeline (preprocessor + XGBoost) inside the artifact."""
    if isinstance(model, Pipeline):
        return model
    est = model.calibrated_classifiers_[0].estimator
    if FrozenEstimator is not None and isinstance(est, FrozenEstimator):
        est = est.estimator
    if not isinstance(est, Pipeline):
        raise TypeError(f"Could not find the base pipeline inside {type(model)}")
    return est


def raw_feature_index(pre) -> list[str]:
    """For each transformed column, the original feature it came from."""
    owners = [None] * len(pre.get_feature_names_out())
    for name, trans, cols in pre.transformers_:
        if name == "remainder" or trans == "drop":
            continue
        sl = pre.output_indices_[name]
        if hasattr(trans, "categories_"):  # one-hot encoder
            out = []
            for col, cats in zip(cols, trans.categories_):
                out += [col] * len(cats)
        else:  # passthrough
            out = list(cols)
        if len(out) != sl.stop - sl.start:
            raise ValueError(f"Column mapping mismatch for transformer '{name}'")
        owners[sl] = out
    return owners


def shap_by_feature(pipe: Pipeline, X: pd.DataFrame):
    """Exact TreeSHAP in log-odds, folded back to original features."""
    pre, clf = pipe.named_steps["pre"], pipe.named_steps["clf"]
    Xt = pre.transform(X)

    best = getattr(clf, "best_iteration", None)
    iteration_range = (0, best + 1) if best is not None else (0, 0)

    contribs = clf.get_booster().predict(
        xgb.DMatrix(Xt, missing=np.nan),
        pred_contribs=True,
        iteration_range=iteration_range,
    )
    phi, bias = contribs[:, :-1], contribs[:, -1]

    # Additivity check: contributions must sum to the model's own margin.
    margin = clf.predict(Xt, output_margin=True)
    max_err = float(np.max(np.abs(phi.sum(axis=1) + bias - margin)))

    owners = raw_feature_index(pre)
    phi_df = pd.DataFrame(phi, columns=owners, index=X.index)
    phi_feat = phi_df.T.groupby(level=0).sum().T  # sum one-hot columns
    return phi_feat, bias, max_err


# ---------------------------------------------------------------------------
# Reason codes
# ---------------------------------------------------------------------------
def group_contributions(phi_feat: pd.DataFrame) -> pd.DataFrame:
    groups = {c: FEATURE_GROUP.get(c, "other") for c in phi_feat.columns}
    return phi_feat.T.groupby(groups).sum().T


def top_reasons(phi_group: pd.DataFrame, k: int, min_logodds: float) -> pd.DataFrame:
    reportable = [g for g in phi_group.columns if g not in NON_REPORTABLE and g in REASON_TEXT]
    vals = phi_group[reportable]
    rows = []
    for idx, r in vals.iterrows():
        ranked = r[r > min_logodds].sort_values(ascending=False).head(k)
        row = {"_idx": idx, "n_reasons": len(ranked)}
        for i, (g, v) in enumerate(ranked.items(), start=1):
            code, text = REASON_TEXT[g]
            row[f"reason_{i}_code"] = code
            row[f"reason_{i}_text"] = text
            row[f"reason_{i}_logodds"] = round(float(v), 4)
        rows.append(row)
    return pd.DataFrame(rows).set_index("_idx")


def direction_check(X: pd.DataFrame, phi_feat: pd.DataFrame) -> dict:
    """Does each feature push risk in the expected direction overall?"""
    out = {}
    for f, sign in EXPECTED_SIGN.items():
        if f not in phi_feat.columns or f not in X.columns:
            continue
        x = pd.to_numeric(X[f], errors="coerce")
        ok = x.notna()
        if ok.sum() < 50 or x[ok].nunique() < 3 or phi_feat.loc[ok, f].nunique() < 2:
            continue  # feature constant or unused by the model
        rho = spearmanr(x[ok], phi_feat.loc[ok, f]).correlation
        out[f] = {
            "spearman_value_vs_shap": round(float(rho), 3),
            "expected_sign": sign,
            "consistent": bool(np.sign(rho) == sign),
        }
    return out


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
def load_rows(cols: list[str]) -> pd.DataFrame:
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


def write_bigquery(df: pd.DataFrame):
    from google.cloud import bigquery

    client = bigquery.Client(project=PROJECT_ID)
    cfg = bigquery.LoadJobConfig(write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE)
    client.load_table_from_dataframe(df, REASONS_TABLE, job_config=cfg).result()
    print(f"Wrote {len(df):,} rows to {REASONS_TABLE}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def run(artifact: dict, df: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    model = artifact["model"]
    num_cols, cat_cols = artifact["num_cols"], artifact["cat_cols"]
    X = df[num_cols + cat_cols]

    # 1. Score and decide
    p = model.predict_proba(X)[:, 1]
    cutoff = float(PD_CUTOFF) if PD_CUTOFF else float(np.quantile(p, 1 - DECLINE_RATE))
    declined = p >= cutoff

    # 2. Explain (all rows, so the direction check sees the full population)
    pipe = unwrap_pipeline(model)
    phi_feat, bias, max_err = shap_by_feature(pipe, X)
    phi_group = group_contributions(phi_feat)

    # 3. Reasons for declined applicants only
    reasons = top_reasons(phi_group[declined], TOP_K, MIN_LOGODDS)
    out = df.loc[declined, ["loan_id"]].copy()
    if "issue_date" in df.columns:
        out["issue_date"] = df.loc[declined, "issue_date"]
    out["p_default"] = p[declined].round(4)
    out = out.join(reasons)

    # 4. Diagnostics
    abs_g = phi_group[declined].abs()
    nonrep_cols = [g for g in abs_g.columns if g in NON_REPORTABLE]
    nonrep_share = (abs_g[nonrep_cols].sum(axis=1) / abs_g.sum(axis=1)).mean() if nonrep_cols else 0.0

    reason_cols = [c for c in out.columns if c.endswith("_code")]
    any_freq = (
        out[reason_cols].stack().dropna().value_counts() / max(1, declined.sum())
    ).round(3)
    first_freq = out["reason_1_code"].value_counts(normalize=True).round(3) if "reason_1_code" in out else pd.Series()

    summary = {
        "model_version": artifact.get("model_version"),
        "split": SPLIT,
        "rows_scored": int(len(df)),
        "pd_cutoff": round(cutoff, 4),
        "declined": int(declined.sum()),
        "decline_rate": round(float(declined.mean()), 4),
        "declined_default_rate": (
            round(float(df.loc[declined, "label"].mean()), 4) if "label" in df.columns else None
        ),
        "additivity_max_error": max_err,
        "share_declined_with_no_reportable_reason": round(float((out["n_reasons"] == 0).mean()), 4),
        "mean_reasons_per_decline": round(float(out["n_reasons"].mean()), 2),
        "nonreportable_share_of_explanation": round(float(nonrep_share), 4),
        "reason_1_frequency": {k: float(v) for k, v in first_freq.items()},
        "reason_in_top_k_frequency": {k: float(v) for k, v in any_freq.items()},
        "direction_check": direction_check(X, phi_feat),
    }
    return out, summary


def main():
    artifact = joblib.load(ARTIFACT_PATH)
    cols = ["loan_id", "issue_date", "label"] + artifact["num_cols"] + artifact["cat_cols"]
    df = load_rows(cols).reset_index(drop=True)
    print(f"Loaded {len(df):,} rows from split='{SPLIT}'")

    out, summary = run(artifact, df)

    os.makedirs(OUT_DIR, exist_ok=True)
    csv_path = os.path.join(OUT_DIR, f"{SPLIT}_reason_codes.csv")
    json_path = os.path.join(OUT_DIR, f"{SPLIT}_summary.json")
    out.to_csv(csv_path, index=False)
    with open(json_path, "w") as f:
        json.dump(summary, f, indent=2)

    print(json.dumps(summary, indent=2))
    print(f"Wrote {csv_path} and {json_path}")

    if summary["additivity_max_error"] > 1e-3:
        print("WARNING: SHAP contributions do not add up to the model margin.")
    if WRITE_BQ:
        write_bigquery(out)


if __name__ == "__main__":
    main()
