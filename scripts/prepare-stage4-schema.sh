#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

db_user="${STAGE4_DB_USERNAME:-game_history}"
db_password="${STAGE4_DB_PASSWORD:-game_history}"
db_name="${STAGE4_DB_NAME:-game_history_lab}"

docker compose up -d --wait mysql

mysql_client=(
    docker compose exec -T
    -e "MYSQL_PWD=$db_password"
    mysql mysql
    --user="$db_user"
    --database="$db_name"
    --default-character-set=utf8mb4
)

"${mysql_client[@]}" < src/main/resources/schema.sql

ensure_column() {
    local table_name="$1"
    local column_definition="$2"
    local exists
    exists="$("${mysql_client[@]}" --batch --skip-column-names --execute "
        SELECT COUNT(*)
        FROM information_schema.columns
        WHERE table_schema = DATABASE()
          AND table_name = '$table_name'
          AND column_name = 'updated_at';
    ")"
    if [[ "$exists" == "0" ]]; then
        echo "Adding $table_name.updated_at"
        "${mysql_client[@]}" --execute "ALTER TABLE $table_name ADD COLUMN $column_definition;"
    fi
}

ensure_index() {
    local table_name="$1"
    local index_name="$2"
    local columns="$3"
    local exists
    exists="$("${mysql_client[@]}" --batch --skip-column-names --execute "
        SELECT COUNT(*)
        FROM information_schema.statistics
        WHERE table_schema = DATABASE()
          AND table_name = '$table_name'
          AND index_name = '$index_name';
    ")"
    if [[ "$exists" == "0" ]]; then
        echo "Adding $table_name.$index_name"
        "${mysql_client[@]}" --execute "ALTER TABLE $table_name ADD INDEX $index_name ($columns);"
    fi
}

ensure_column games "updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)"
ensure_column rounds "updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)"
ensure_column round_scores "updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)"

ensure_index games idx_games_updated_at "updated_at, id"
ensure_index rounds idx_rounds_updated_at "updated_at, game_id"
ensure_index round_scores idx_round_scores_updated_at "updated_at, round_id"

"${mysql_client[@]}" --table --execute "
    SELECT table_name, index_name, GROUP_CONCAT(column_name ORDER BY seq_in_index) AS columns_in_order
    FROM information_schema.statistics
    WHERE table_schema = DATABASE()
      AND index_name IN ('idx_games_updated_at', 'idx_rounds_updated_at', 'idx_round_scores_updated_at')
    GROUP BY table_name, index_name
    ORDER BY table_name;
"
