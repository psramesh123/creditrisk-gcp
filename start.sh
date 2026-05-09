#!/usr/bin/env bash
set -e
cd ~/creditrisk-gcp
gcloud config set project project-01523b1d-fc19-4c00-97e >/dev/null
gcloud config set compute/region northamerica-northeast1 >/dev/null
gcloud config set compute/zone northamerica-northeast1-a >/dev/null

export PROJECT_ID="project-01523b1d-fc19-4c00-97e"
export BQ_DATASET="creditrisk"
export BUCKET="project-01523b1d-fc19-4c00-97e-creditrisk"

source .venv/bin/activate 2>/dev/null || source venv/bin/activate
echo "Ready: PROJECT_ID=$PROJECT_ID, BQ_DATASET=$BQ_DATASET, BUCKET=$BUCKET"
