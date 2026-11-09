#!/usr/bin/env bash
set -euo pipefail

# Export the dash_* views (sql/07_dashboard_views.sql) to CSV for the
# Tableau workbook. The files are small aggregates (no loan-level rows), so
# they are committed and the workbook needs no BigQuery connection.

# ----- Resolve project root regardless of where the script is invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ----- Config (overridable via env)
: "${PROJECT_ID:=project-01523b1d-fc19-4c00-97e}"
: "${BQ_DATASET:=creditrisk}"
OUT_DIR="extracts"
mkdir -p "${OUT_DIR}"

# view name | sort order (stable row order keeps git diffs between exports small)
while IFS='|' read -r view order_by; do
  printf 'Exporting %s ... ' "${view}"
  # --quiet keeps job-status lines out of the CSV
  bq --quiet --project_id="${PROJECT_ID}" query \
    --use_legacy_sql=false --format=csv --max_rows=1000000 \
    "SELECT * FROM \`${PROJECT_ID}.${BQ_DATASET}.${view}\` ORDER BY ${order_by}" \
    > "${OUT_DIR}/${view}.csv"
  echo "$(( $(wc -l < "${OUT_DIR}/${view}.csv") - 1 )) rows"
done <<'EOF'
dash_summary|split
dash_risk_bands|split, risk_band, loan_term
dash_score_trend|split, issue_month
dash_feature_drift|split, feature_name, issue_month
dash_alerts|severity_rank, split, issue_month
EOF

echo "Done. Files in tableau/${OUT_DIR}/"
