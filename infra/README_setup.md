# GCP Setup Guide

Step-by-step instructions for setting up the Google Cloud Platform resources
required to run the credit risk pipeline on a fresh project. Follow this
once per GCP project; the main `README.md` covers the day-to-day workflow
once setup is complete.

This guide assumes you are working from **Cloud Shell**, which already has
`gcloud`, `bq`, `python`, and authenticated credentials available. If you
are working from a local machine, you will additionally need to install the
[Google Cloud SDK](https://cloud.google.com/sdk/docs/install) and run
`gcloud auth login` and `gcloud auth application-default login`.

---

## Prerequisites

- A Google Cloud account with billing enabled (the Lending Club dataset is
  small enough to fit comfortably in the free tier; expect <$1 in BigQuery
  costs for a full run)
- A GCP project (create a new one or reuse an existing one)
- Python 3.12 or newer

---

## 1. Set the active project

Replace `YOUR_PROJECT_ID` with your actual project ID:

```bash
export PROJECT_ID="YOUR_PROJECT_ID"
gcloud config set project "${PROJECT_ID}"
```

Verify:

```bash
gcloud config get-value project
```

---

## 2. Enable the required APIs

The pipeline uses BigQuery for storage and Cloud Storage as an optional
staging area for the raw CSV. Enable both:

```bash
gcloud services enable bigquery.googleapis.com
gcloud services enable storage.googleapis.com
gcloud services enable bigquerystorage.googleapis.com
```

The BigQuery Storage API is what powers the fast `to_dataframe()` path used
in `src/train/train.py`.

---

## 3. Create the BigQuery dataset

The pipeline writes everything into a single dataset named `creditrisk`.

```bash
export BQ_DATASET="creditrisk"
bq --location=US mk --dataset "${PROJECT_ID}:${BQ_DATASET}"
```

Verify:

```bash
bq ls "${PROJECT_ID}:${BQ_DATASET}"
```

(Should return an empty result — the dataset exists but contains no tables yet.)

If you prefer a different region, replace `US` with the appropriate location
(e.g. `EU`, `asia-northeast1`). Cloud Shell defaults to US-region resources.

---

## 4. (Optional) Create a Cloud Storage bucket for raw CSV

If you want to stage the Lending Club CSV in Cloud Storage rather than
loading it directly from local disk, create a bucket:

```bash
export BUCKET="${PROJECT_ID}-creditrisk"
gcloud storage buckets create "gs://${BUCKET}" --location=US
```

Otherwise, you can skip this and place the CSV directly at `data/loans.csv`
in the project directory; `src/ingest/upload_and_load.py` handles both paths.

---

## 5. IAM and service accounts

For Cloud Shell development, your **user account** already has the
permissions needed (typically `Owner` or `Editor` on the project). No
additional service account setup is required for the basic flow.

For automation outside Cloud Shell (e.g. running `train.py` from a
Compute Engine VM, Cloud Run job, or Vertex AI custom job), create a
service account with the following roles:

```bash
export SA_NAME="creditrisk-runner"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="Credit Risk Pipeline Runner"

# BigQuery: read features, write predictions and metrics
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.dataEditor"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.jobUser"

# Cloud Storage (only if using the bucket from step 4)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin"
```

For local development from a personal machine, run:

```bash
gcloud auth application-default login
```

This sets up Application Default Credentials that the BigQuery Python client
will pick up automatically.

---

## 6. Initialise the project tables

From the project root:

```bash
cd ~/creditrisk-gcp
bq query --use_legacy_sql=false < sql/01_create_tables.sql
bq query --use_legacy_sql=false < sql/03_monitoring_tables.sql
```

This creates:
- `loans_raw`, `predictions`, `model_metrics` (core)
- `score_drift`, `feature_drift`, `monitoring_rollups`, `monitoring_alerts` (monitoring)
- `*_latest` views over each monitoring table

Both scripts use `CREATE TABLE IF NOT EXISTS` and `CREATE OR REPLACE VIEW`,
so they are safe to re-run.

Verify:

```bash
bq ls --format=pretty "${PROJECT_ID}:${BQ_DATASET}"
```

You should see 7 tables and 4 views.

---

## 7. Set up the Python environment

```bash
cd ~/creditrisk-gcp
python -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r src/train/requirements.txt
```

Verify the key dependencies installed correctly:

```bash
python -c "import sklearn, xgboost, google.cloud.bigquery; \
  print('sklearn', sklearn.__version__); \
  print('xgboost', xgboost.__version__)"
```

You should see `sklearn 1.6.x` (or higher) and `xgboost 2.x.x` (or higher).

---

## 8. Wire up the bootstrap script

The repo includes `start.sh`, which sources environment variables and
activates the virtualenv at the start of each Cloud Shell session.

If you used different values for `PROJECT_ID`, `BQ_DATASET`, or `BUCKET`
than the defaults, edit `start.sh` to reflect them. Then test:

```bash
source start.sh
```

You should see `Ready: PROJECT_ID=... BQ_DATASET=... BUCKET=...`.

---

## 9. Load the Lending Club dataset

Download the Lending Club public loan-level CSV from
[Kaggle](https://www.kaggle.com/datasets) (search for "Lending Club Loan
Data") or from any public mirror, and place it at:

```
~/creditrisk-gcp/data/loans.csv
```

Then load it into BigQuery:

```bash
python -m src.ingest.upload_and_load
```

The script handles both local-file and GCS-staged loads. After loading,
verify row count:

```bash
bq query --use_legacy_sql=false \
  "SELECT COUNT(*) AS n FROM \`${PROJECT_ID}.${BQ_DATASET}.loans_raw\`"
```

Expect ~2 million rows for the full Lending Club public dataset.

---

## 10. Build features and train

```bash
# Build the feature table with label, time split, and maturity guard
bq query --use_legacy_sql=false < sql/02_build_features.sql

# Train the calibrated XGBoost model (~10-15 minutes on Cloud Shell)
python src/train/train.py
```

Once training completes, verify the artifact and metrics:

```bash
ls -lh artifacts/model.joblib

bq query --use_legacy_sql=false --format=pretty \
  "SELECT split, ROUND(roc_auc, 4) AS roc_auc, ROUND(brier, 4) AS brier
   FROM \`${PROJECT_ID}.${BQ_DATASET}.model_metrics\`
   ORDER BY ts DESC LIMIT 2"
```

You're done with setup. From this point on, the daily workflow is:

```bash
source start.sh
./run_monitoring.sh    # re-score and refresh monitoring
```

See the main `README.md` for full operational details.

---

## Troubleshooting

**`bq: command not found`** — You're not in Cloud Shell, and the Cloud SDK
isn't installed. Install from
[cloud.google.com/sdk/docs/install](https://cloud.google.com/sdk/docs/install).

**`Permission denied` on BigQuery operations** — Your account doesn't have
`BigQuery Data Editor` and `BigQuery Job User` roles on the project. Grant
them via IAM in the Cloud Console.

**`google.api_core.exceptions.NotFound: 404 Not found: Table ...`** — You
skipped step 6. Re-run both `01_create_tables.sql` and `03_monitoring_tables.sql`.

**`ModuleNotFoundError: No module named 'sklearn.frozen'`** — Your scikit-learn
version is older than 1.6. Upgrade with `pip install -U scikit-learn`.

**`pip install` is slow or fails on Cloud Shell** — Cloud Shell's
`/home` directory is small (~5 GB). If you hit space limits, run
`pip cache purge` and try again.

**Training takes longer than expected** — Cloud Shell VMs are small (1-2
vCPU, 4 GB RAM). For a full run on the complete dataset, expect 10-15
minutes. For faster iteration during development, set `BQ_LIMIT=20000`
to subsample.
