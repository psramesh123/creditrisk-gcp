import os
import csv
from google.cloud import storage
from google.cloud import bigquery

PROJECT_ID = os.environ["PROJECT_ID"]
BUCKET = os.environ["BUCKET"]          # e.g. PROJECT_ID-creditrisk
BQ_DATASET = os.environ["BQ_DATASET"]  # creditrisk
GCS_OBJECT = "raw/loans.csv"
BQ_TABLE = f"{PROJECT_ID}.{BQ_DATASET}.loans_raw"

def upload_to_gcs(local_path: str):
    client = storage.Client()
    bucket = client.bucket(BUCKET)
    blob = bucket.blob(GCS_OBJECT)
    blob.upload_from_filename(local_path)
    print(f"Uploaded to gs://{BUCKET}/{GCS_OBJECT}")

def load_to_bigquery():
    bq = bigquery.Client()

    # Read header to build STRING schema for all columns
    with open("data/loans.csv", "r", newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        header = next(reader)

    schema = [bigquery.SchemaField(col.strip(), "STRING") for col in header]

    job_config = bigquery.LoadJobConfig(
        schema=schema,  # <-- force strings
        source_format=bigquery.SourceFormat.CSV,
        skip_leading_rows=1,
        write_disposition="WRITE_TRUNCATE",
        allow_quoted_newlines=True,
        allow_jagged_rows=True,
        max_bad_records=1000,  # allow some dirty rows
    )

    uri = f"gs://{BUCKET}/{GCS_OBJECT}"
    load_job = bq.load_table_from_uri(uri, BQ_TABLE, job_config=job_config)
    load_job.result()
    print(f"Loaded {BQ_TABLE}")

if __name__ == "__main__":
    upload_to_gcs("data/loans.csv")
    load_to_bigquery()
