#!/usr/bin/env bash
# Export the dashboard views to CSV, for building the Power BI report from files
# instead of a live BigQuery connection. Run in Cloud Shell (bq is preinstalled),
# then download powerbi/data/ and point Power BI at the CSVs (see BUILD_GUIDE.md).
set -euo pipefail

PROJECT="project-01523b1d-fc19-4c00-97e"
DATASET="creditrisk"
OUT="$(dirname "$0")/data"
mkdir -p "$OUT"

for view in model_metrics_latest monitoring_rollups_latest score_drift_latest \
            feature_drift_latest monitoring_alerts_latest; do
  echo "exporting ${view}"
  bq query --nouse_legacy_sql --format=csv --max_rows=1000000 --quiet \
    "SELECT * FROM \`${PROJECT}.${DATASET}.${view}\`" > "${OUT}/${view}.csv"
done

echo "wrote $(ls "$OUT" | wc -l | tr -d ' ') files to ${OUT}"
