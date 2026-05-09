import os
import json
import joblib
import numpy as np
import pandas as pd
from google.cloud import bigquery
from sklearn.metrics import roc_auc_score, average_precision_score, brier_score_loss


PROJECT_ID = os.environ.get("PROJECT_ID", "project-01523b1d-fc19-4c00-97e")
BQ_DATASET = os.environ.get("BQ_DATASET", "creditrisk")
FEATURES_TABLE = os.environ.get("FEATURES_TABLE", f"{PROJECT_ID}.{BQ_DATASET}.features")

ARTIFACT_PATH = os.environ.get("ARTIFACT_PATH", "artifacts/model.joblib")
SPLIT_COL = "split"
LABEL_COL = "label"


def compute_metrics(y_true: np.ndarray, p: np.ndarray) -> dict:
    out = {
        "roc_auc": float(roc_auc_score(y_true, p)),
        "pr_auc": float(average_precision_score(y_true, p)),
        "brier": float(brier_score_loss(y_true, p)),
    }
    for frac in (0.01, 0.05, 0.10):
        k = max(1, int(len(p) * frac))
        idx = np.argsort(-p)[:k]
        y_top = y_true[idx]
        out[f"top_{int(frac*100)}pct_precision"] = float(y_top.mean())
        out[f"top_{int(frac*100)}pct_recall"] = float(y_top.sum() / max(1, y_true.sum()))
    return out


def load_split(client: bigquery.Client, split: str, cols: list[str]) -> pd.DataFrame:
    q = f"""
    SELECT {", ".join(cols)}
    FROM `{FEATURES_TABLE}`
    WHERE {SPLIT_COL} = @split
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("split", "STRING", split)]
    )
    return client.query(q, job_config=job_config).to_dataframe()


def main():
    if not os.path.exists(ARTIFACT_PATH):
        raise FileNotFoundError(f"Model artifact not found: {ARTIFACT_PATH}. Run train.py first.")

    artifact = joblib.load(ARTIFACT_PATH)
    model = artifact["model"]
    model_version = artifact.get("model_version", "unknown")

    num_cols = artifact["num_cols"]
    cat_cols = artifact["cat_cols"]
    cols = [LABEL_COL] + num_cols + cat_cols

    client = bigquery.Client(project=PROJECT_ID)

    for split in ("train", "valid", "test"):
        df = load_split(client, split, cols)
        if len(df) == 0:
            print(f"{split.upper()}: (empty) - skipping")
            continue

        X = df[num_cols + cat_cols]
        y = df[LABEL_COL].astype(int).to_numpy()
        p = model.predict_proba(X)[:, 1]

        metrics = compute_metrics(y, p)
        print(f"{split.upper()} metrics (model_version={model_version}):")
        print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
