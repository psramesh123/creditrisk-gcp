from datetime import datetime

from airflow.sdk import DAG
from airflow.providers.standard.operators.bash import BashOperator

REPO = "/home/sagiping/creditrisk-gcp"
PROJECT = "project-01523b1d-fc19-4c00-97e"

# Each task runs in a fresh shell: load project env + the main .venv first.
SETUP = (
    f"cd {REPO} && source start.sh && "
    "export DBT_ENGINE_MANAGE_STATE=false && "
    f"export FEATURES_TABLE={PROJECT}.creditrisk_dbt.features"
)

with DAG(
    dag_id="creditrisk_pipeline",
    schedule=None,              # run manually for now
    start_date=datetime(2026, 1, 1),
    catchup=False,
    tags=["creditrisk"],
) as dag:
    dbt_build = BashOperator(
        task_id="dbt_build",
        bash_command=f"{SETUP} && cd dbt && dbt build",
    )
    train = BashOperator(
        task_id="train_model",
        bash_command=f"{SETUP} && python src/train/train.py",
    )
    monitor = BashOperator(
        task_id="run_monitoring",
        bash_command=f"{SETUP} && bash run_monitoring.sh && echo monitoring_done",
    )

    dbt_build >> train >> monitor
