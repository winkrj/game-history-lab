#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

stage3_db_user="${STAGE3_DB_USERNAME:-game_history}"
stage3_db_password="${STAGE3_DB_PASSWORD:-game_history}"
stage3_db_name="${STAGE3_DB_NAME:-game_history_lab}"

mysql_client=(
    docker compose exec -T
    -e "MYSQL_PWD=$stage3_db_password"
    mysql mysql
    --user="$stage3_db_user"
    --database="$stage3_db_name"
    --default-character-set=utf8mb4
)

"${mysql_client[@]}" --table --execute "
    SELECT
        ji.JOB_INSTANCE_ID,
        je.JOB_EXECUTION_ID,
        je.STATUS AS JOB_STATUS,
        je.START_TIME,
        je.END_TIME,
        se.STEP_EXECUTION_ID,
        se.STATUS AS STEP_STATUS,
        se.READ_COUNT,
        se.WRITE_COUNT,
        se.COMMIT_COUNT,
        se.ROLLBACK_COUNT
    FROM BATCH_JOB_INSTANCE ji
    JOIN BATCH_JOB_EXECUTION je ON je.JOB_INSTANCE_ID = ji.JOB_INSTANCE_ID
    LEFT JOIN BATCH_STEP_EXECUTION se ON se.JOB_EXECUTION_ID = je.JOB_EXECUTION_ID
    WHERE ji.JOB_NAME = 'gameHistoryReadModelJob'
    ORDER BY je.JOB_EXECUTION_ID DESC, se.STEP_EXECUTION_ID;

    SELECT
        (SELECT COUNT(*) FROM games) AS source_games,
        (SELECT COUNT(*) FROM game_history_read_model) AS read_model_rows,
        (
            SELECT COUNT(*)
            FROM game_history_read_model rm
            LEFT JOIN games g ON g.id = rm.game_id
            WHERE g.id IS NULL
        ) AS extra_read_model_rows,
        (
            SELECT COUNT(*)
            FROM games g
            LEFT JOIN game_history_read_model rm ON rm.game_id = g.id
            WHERE rm.game_id IS NULL
        ) AS missing_read_model_rows;
"

./scripts/check-stage2-read-model.sh
