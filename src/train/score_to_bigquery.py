import os
import joblib
import pandas as pd
from google.cloud import bigquery

PROJECT_ID = os.environ.get("PROJECT_ID", "project-01523b1d-fc19-4c00-97e")
BQ_DATASET = os.environ.get("BQ_DATASET", "creditrisk")

FEATURES_TABLE = os.environ.get("FEATURES_TABLE", f"{PROJECT_ID}.{BQ_DATASET}.features")
PRED_TABLE = os.environ.get("PRED_TABLE", f"{PROJECT_ID}.{BQ_DATASET}.predictions")

ARTIFACT_PATH = os.environ.get("ARTIFACT_PATH", "artifacts/model.joblib")
SPLIT = os.environ.get("SCORE_SPLIT", "test")

def ensure_predictions_table(client: bigquery.Client):
    schema = [
        bigquery.SchemaField("ts", "TIMESTAMP"),
        bigquery.SchemaField("model_version", "STRING"),
        bigquery.SchemaField("split", "STRING"),
        bigquery.SchemaField("loan_id", "STRING"),
        bigquery.SchemaField("issue_date", "DATE"),
        bigquery.SchemaField("p_default", "FLOAT"),
    ]
    try:
        client.get_table(PRED_TABLE)
    except Exception:
        client.create_table(bigquery.Table(PRED_TABLE, schema=schema))

def load_split_df(client: bigquery.Client, split: str, cols: list[str]) -> pd.DataFrame:
    q = f"""
    SELECT {", ".join(cols)}
    FROM `{FEATURES_TABLE}`
    WHERE split = @split
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

    cols = ["loan_id", "issue_date"] + num_cols + cat_cols

    client = bigquery.Client(project=PROJECT_ID)
    ensure_predictions_table(client)

    print(f"Scoring split='{SPLIT}' from {FEATURES_TABLE}")
    df = load_split_df(client, SPLIT, cols)
    print(f"Loaded {len(df):,} rows")

    X = df[num_cols + cat_cols]
    p = model.predict_proba(X)[:, 1]

    out = df[["loan_id", "issue_date"]].copy()
    out["p_default"] = p
    out["split"] = SPLIT
    out["model_version"] = model_version
    out["ts"] = pd.Timestamp.utcnow()  # timestamp column

    # Ensure proper dtypes for BigQuery load job
    out["issue_date"] = pd.to_datetime(out["issue_date"]).dt.date

    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND
    )

    print(f"Loading {len(out):,} rows into {PRED_TABLE} via load job...")
    job = client.load_table_from_dataframe(out, PRED_TABLE, job_config=job_config)
    job.result()
    print("Done.")
    print(f"Model version: {model_version}")

if __name__ == "__main__":
    main()
