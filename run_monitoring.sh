#!/usr/bin/env bash
set -euo pipefail
 
# ----- Resolve project root regardless of where the script is invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
 
# ----- Config (overridable via env)
: "${PROJECT_ID:=project-01523b1d-fc19-4c00-97e}"
: "${BQ_DATASET:=creditrisk}"
export PROJECT_ID BQ_DATASET
 
# ----- Logging helpers
log()  { printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"; }
fail() { printf '\n[%s] ERROR: %s\n' "$(date +'%H:%M:%S')" "$*" >&2; exit 1; }
 
# ----- Preflight checks
[[ -f artifacts/model.joblib ]] || fail "artifacts/model.joblib not found. Run 'python src/train/train.py' first."
command -v bq     >/dev/null || fail "bq CLI not found on PATH."
command -v python >/dev/null || fail "python not found on PATH. Activate the virtualenv."
 
log "Starting monitoring refresh for ${PROJECT_ID}.${BQ_DATASET}"
 
# ============================================================================
# 1) Score valid + test into BigQuery
# ============================================================================
log "[1/3] Scoring VALID split into ${BQ_DATASET}.predictions"
SCORE_SPLIT=valid python src/train/score_to_bigquery.py
 
log "[1/3] Scoring TEST split into ${BQ_DATASET}.predictions"
SCORE_SPLIT=test  python src/train/score_to_bigquery.py
 
# ============================================================================
# 2) Refresh drift tables
# ============================================================================

log "[2/3] Refreshing score drift table"
bq query --use_legacy_sql=false < sql/05_score_drift.sql

log "[2/3] Refreshing monitoring rollups"
bq query --use_legacy_sql=false < sql/06_monitoring_rollups.sql

log "[2/3] Refreshing feature drift table"
bq query --use_legacy_sql=false < sql/04_feature_drift.sql


# ============================================================================
# 3) Run alert checks
# ============================================================================
log "[3/3] Running alert: score p90 drift"
bq query --use_legacy_sql=false < sql/monitoring/10_alert_score_p90.sql
 
log "[3/3] Running alert: numeric feature mean drift"
bq query --use_legacy_sql=false < sql/monitoring/11_alert_numeric_mean.sql
 
log "[3/3] Running alert: categorical top-share drift"
bq query --use_legacy_sql=false < sql/monitoring/12_alert_categorical_share.sql
 
log "Monitoring refresh complete."
 