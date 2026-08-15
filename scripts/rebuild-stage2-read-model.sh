#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

read_model_db_user="${READ_MODEL_DB_USERNAME:-game_history}"
read_model_db_password="${READ_MODEL_DB_PASSWORD:-game_history}"
read_model_db_name="${READ_MODEL_DB_NAME:-game_history_lab}"

docker compose up -d --wait mysql

mysql_client=(
    docker compose exec -T
    -e "MYSQL_PWD=$read_model_db_password"
    mysql mysql
    --user="$read_model_db_user"
    --database="$read_model_db_name"
    --default-character-set=utf8mb4
)

"${mysql_client[@]}" < src/main/resources/schema.sql

source_game_count="$("${mysql_client[@]}" --batch --skip-column-names --execute "SELECT COUNT(*) FROM games")"
source_game_count="${source_game_count//$'\r'/}"
if [[ "$source_game_count" == "0" ]]; then
    echo "Source games are empty. Generate Stage 1 data before rebuilding the Read Model." >&2
    exit 1
fi

echo "Rebuilding Stage 2 Read Model from $source_game_count Source games."
"${mysql_client[@]}" --table < src/main/resources/stage2-rebuild-read-model.sql

READ_MODEL_DB_USERNAME="$read_model_db_user" \
READ_MODEL_DB_PASSWORD="$read_model_db_password" \
READ_MODEL_DB_NAME="$read_model_db_name" \
    ./scripts/check-stage2-read-model.sh
