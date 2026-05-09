import os
import json
import time
import joblib
import numpy as np
import pandas as pd
from google.cloud import bigquery

from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder
from sklearn.calibration import CalibratedClassifierCV
from sklearn.metrics import roc_auc_score, average_precision_score, brier_score_loss
from xgboost import XGBClassifier
from sklearn.frozen import FrozenEstimator


# ----------------------------
# Config (via environment)
# ----------------------------
PROJECT_ID = os.environ.get("PROJECT_ID", "project-01523b1d-fc19-4c00-97e")
BQ_DATASET = os.environ.get("BQ_DATASET", "creditrisk")
FEATURES_TABLE = os.environ.get(
    "FEATURES_TABLE",
    f"{PROJECT_ID}.{BQ_DATASET}.features"
)

ARTIFACT_DIR = os.environ.get("ARTIFACT_DIR", "artifacts")
MODEL_PATH = os.path.join(ARTIFACT_DIR, "model.joblib")

# Calibration enabled by default (as requested)
CALIBRATE = os.environ.get("CALIBRATE", "1") not in ("0", "false", "False", "")

# Features expected from your features table
NUM_COLS = [
    # loan terms
    "loan_amount",
    "interest_rate",
    "installment",
    "term_months",

    # borrower
    "annual_income",
    "dti",

    # FICO
    "fico_low",
    "fico_high",

    # accounts
    "open_acc",
    "total_acc",
    "pub_rec",

    # delinquency / inquiries
    "delinq_2yrs",
    "inq_last_6mths",

    # utilisation / balances
    "revol_bal",
    "revol_util",

    # derived
    "credit_history_years",
]

CAT_COLS = [
    "home_ownership",
    "grade",
    "purpose",
    "verification_status",
    "initial_list_status",
    "emp_length",
]

LABEL_COL = "label"
SPLIT_COL = "split"


# ----------------------------
# BigQuery loading
# ----------------------------
def load_split(split: str, limit: int | None = None) -> pd.DataFrame:
    """
    Load a split from BigQuery. Optionally limit for quicker debugging.
    """
    client = bigquery.Client(project=PROJECT_ID)
    select_cols = ["loan_id", "issue_date", LABEL_COL, SPLIT_COL] + NUM_COLS + CAT_COLS

    q = f"""
    SELECT {", ".join(select_cols)}
    FROM `{FEATURES_TABLE}`
    WHERE {SPLIT_COL} = @split
    """

    if limit is not None:
        q += f" LIMIT {int(limit)}"

    job_config = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("split", "STRING", split)]
    )
    df = client.query(q, job_config=job_config).to_dataframe(create_bqstorage_client=True)
    return df


# ----------------------------
# Model building
# ----------------------------
def build_pipeline() -> Pipeline:
    pre = ColumnTransformer(
        transformers=[
            ("cat", OneHotEncoder(handle_unknown="ignore"), CAT_COLS),
            ("num", "passthrough", NUM_COLS),
        ],
        remainder="drop",
    )

    # Solid baseline for tabular credit risk
    model = XGBClassifier(
        n_estimators=2000,
        max_depth=4,
        learning_rate=0.05,
        subsample=0.9,
        colsample_bytree=0.9,
        reg_lambda=1.0,
        min_child_weight=1.0,
        gamma=0.0,
        objective="binary:logistic",
        eval_metric="logloss",
        early_stopping_rounds=50,
        tree_method="hist",
        n_jobs=-1,
    )

    return Pipeline([("pre", pre), ("clf", model)])


def compute_metrics(y_true: np.ndarray, p: np.ndarray) -> dict:
    base_rate = float(y_true.mean())
    out = {
        "roc_auc": float(roc_auc_score(y_true, p)),
        "pr_auc": float(average_precision_score(y_true, p)),
        "brier": float(brier_score_loss(y_true, p)),
        "base_rate": base_rate,
    }

    # Top-K default rate, lift and recall
    for frac in (0.01, 0.05, 0.10):
        k = max(1, int(len(p) * frac))
        idx = np.argsort(-p)[:k]
        y_top = y_true[idx]
        top_default_rate = float(y_top.mean())
        out[f"top_{int(frac*100)}pct_default_rate"] = top_default_rate
        out[f"lift_at_{int(frac*100)}pct"] = top_default_rate / base_rate if base_rate > 0 else 0.0
        out[f"recall_at_{int(frac*100)}pct"] = float(y_top.sum() / max(1, y_true.sum()))
    return out


def write_metrics_to_bigquery(metrics: dict, split_name: str, model_version: str):
    client = bigquery.Client(project=PROJECT_ID)
    table_id = f"{PROJECT_ID}.{BQ_DATASET}.model_metrics"

    # Create table if not exists (simple schema)
    schema = [
        bigquery.SchemaField("ts", "TIMESTAMP"),
        bigquery.SchemaField("model_version", "STRING"),
        bigquery.SchemaField("split", "STRING"),
        bigquery.SchemaField("metrics_json", "STRING"),
        bigquery.SchemaField("roc_auc", "FLOAT"),
        bigquery.SchemaField("pr_auc", "FLOAT"),
        bigquery.SchemaField("brier", "FLOAT"),
        bigquery.SchemaField("top_1pct_precision", "FLOAT"),
        bigquery.SchemaField("top_1pct_recall", "FLOAT"),
        bigquery.SchemaField("top_5pct_precision", "FLOAT"),
        bigquery.SchemaField("top_5pct_recall", "FLOAT"),
        bigquery.SchemaField("top_10pct_precision", "FLOAT"),
        bigquery.SchemaField("top_10pct_recall", "FLOAT"),
    ]

    try:
        client.get_table(table_id)
    except Exception:
        client.create_table(bigquery.Table(table_id, schema=schema))

    row = {
        "ts": pd.Timestamp.utcnow().isoformat(),
        "model_version": model_version,
        "split": split_name,
        "metrics_json": json.dumps(metrics, default=str),
        "roc_auc": metrics.get("roc_auc"),
        "pr_auc": metrics.get("pr_auc"),
        "brier": metrics.get("brier"),
        "top_1pct_precision": metrics.get("top_1pct_default_rate"),
        "top_1pct_recall": metrics.get("recall_at_1pct"),
        "top_5pct_precision": metrics.get("top_5pct_default_rate"),
        "top_5pct_recall": metrics.get("recall_at_5pct"),
        "top_10pct_precision": metrics.get("top_10pct_default_rate"),
        "top_10pct_recall": metrics.get("recall_at_10pct"),
    }

    errors = client.insert_rows_json(table_id, [row])
    if errors:
        raise RuntimeError(f"BigQuery insert errors: {errors}")


def main():
    os.makedirs(ARTIFACT_DIR, exist_ok=True)

    # Optional: set LIMIT for faster debug runs
    limit = os.environ.get("BQ_LIMIT")
    limit = int(limit) if limit else None

    print(f"Loading train/valid/test from BigQuery table: {FEATURES_TABLE}")
    train_df = load_split("train", limit=limit)
    valid_df = load_split("valid", limit=limit)
    test_df = load_split("test", limit=limit)
    print(f"Loaded rows -- train: {len(train_df):,} | valid: {len(valid_df):,} | test: {len(test_df):,}")

    if len(test_df) == 0:
        print("WARNING: test split is empty. Ensure your SQL splitting logic creates 'test'.")
        print("Proceeding with train+valid only (evaluation will skip test).")

    # Separate X/y
    X_train = train_df[NUM_COLS + CAT_COLS]
    y_train = train_df[LABEL_COL].astype(int).to_numpy()

    X_valid = valid_df[NUM_COLS + CAT_COLS]
    y_valid = valid_df[LABEL_COL].astype(int).to_numpy()

    # Base model
    pipe = build_pipeline()
    print("Training base model on TRAIN with early stopping on VALID...")
    preprocessor = pipe.named_steps["pre"]
    classifier = pipe.named_steps["clf"]
 
    X_train_t = preprocessor.fit_transform(X_train)
    X_valid_t = preprocessor.transform(X_valid)
 
    classifier.fit(
        X_train_t, y_train,
        eval_set=[(X_valid_t, y_valid)],
        verbose=False,
    )
    print(f"Best iteration: {classifier.best_iteration} of {classifier.n_estimators}")
 
    # Reassemble pipeline so calibration / scoring see a normal sklearn Pipeline
    pipe = Pipeline([("pre", preprocessor), ("clf", classifier)])
 

    if CALIBRATE:
        print("Calibrating on VALID with isotonic regression (frozen base estimator)...")
        model = CalibratedClassifierCV(
            estimator=FrozenEstimator(pipe),
            method="isotonic",
            cv=None,
        )
        model.fit(X_valid, y_valid)
    else:
        model = pipe


    # Version stamp
    model_version = time.strftime("%Y%m%d-%H%M%S")

    # Evaluate on valid (and test if exists)
    print("Evaluating...")
    p_valid = model.predict_proba(X_valid)[:, 1]
    valid_metrics = compute_metrics(y_valid, p_valid)
    print("VALID metrics:", valid_metrics)
    write_metrics_to_bigquery(valid_metrics, "valid", model_version)

    test_metrics = None
    if len(test_df) > 0:
        X_test = test_df[NUM_COLS + CAT_COLS]
        y_test = test_df[LABEL_COL].astype(int).to_numpy()
        p_test = model.predict_proba(X_test)[:, 1]
        test_metrics = compute_metrics(y_test, p_test)
        print("TEST metrics:", test_metrics)
        write_metrics_to_bigquery(test_metrics, "test", model_version)

    # Save artifact
    artifact = {
        "model": model,
        "model_version": model_version,
        "project_id": PROJECT_ID,
        "bq_dataset": BQ_DATASET,
        "features_table": FEATURES_TABLE,
        "num_cols": NUM_COLS,
        "cat_cols": CAT_COLS,
        "calibrated": CALIBRATE,
        "best iteration": int(classifier.best_iteration),
        "valid_metrics": valid_metrics,
        "test_metrics": test_metrics,
    }
    joblib.dump(artifact, MODEL_PATH)
    print(f"Saved model artifact to {MODEL_PATH}")


if __name__ == "__main__":
    main()
