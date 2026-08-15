#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

result_dir="${1:?Usage: $0 BENCHMARK_RESULT_DIRECTORY}"
explain_dir="$result_dir/explain"
explain_db_user="${EXPLAIN_DB_USERNAME:-game_history}"
explain_db_password="${EXPLAIN_DB_PASSWORD:-game_history}"
explain_db_name="${EXPLAIN_DB_NAME:-game_history_lab}"

if [[ ! -f "$result_dir/metadata.txt" ]]; then
    echo "Not a Stage 2 benchmark result directory: $result_dir" >&2
    exit 1
fi
if [[ -e "$explain_dir" ]]; then
    echo "EXPLAIN result directory already exists: $explain_dir" >&2
    exit 1
fi

mkdir "$explain_dir"

mysql_client=(
    docker compose exec -T
    -e "MYSQL_PWD=$explain_db_password"
    mysql mysql
    --user="$explain_db_user"
    --database="$explain_db_name"
)

build_original_query() {
    local from_value="$1"
    local offset_value="$2"
    printf '%s\n' "SELECT g.id AS game_id, s.id AS shop_id, g.played_at, g.player_nickname, g.course_name, COALESCE(SUM(rs.score), 0) AS total_score, COUNT(DISTINCT r.id) AS round_count, g.game_status FROM games g JOIN shops s ON s.id = g.shop_id LEFT JOIN rounds r ON r.game_id = g.id LEFT JOIN round_scores rs ON rs.round_id = r.id WHERE s.id = 1 AND g.played_at >= '$from_value' AND g.played_at < '2026-01-01 00:00:00.000000' GROUP BY g.id, s.id, g.played_at, g.player_nickname, g.course_name, g.game_status ORDER BY g.played_at DESC, g.id DESC LIMIT 20 OFFSET $offset_value;"
}

build_read_model_query() {
    local from_value="$1"
    local offset_value="$2"
    printf '%s\n' "SELECT game_id, shop_id, played_at, player_nickname, course_name, total_score, round_count, game_status FROM game_history_read_model WHERE shop_id = 1 AND played_at >= '$from_value' AND played_at < '2026-01-01 00:00:00.000000' ORDER BY played_at DESC, game_id DESC LIMIT 20 OFFSET $offset_value;"
}

capture_query() {
    local artifact_id="$1"
    local query_sql="$2"

    printf '%s\n' "$query_sql" > "$explain_dir/$artifact_id.sql"
    "${mysql_client[@]}" --batch --raw --skip-column-names --execute "EXPLAIN ANALYZE FORMAT=TREE $query_sql" > "$explain_dir/$artifact_id-analyze-tree.txt"
    "${mysql_client[@]}" --batch --raw --skip-column-names --execute "EXPLAIN FORMAT=JSON $query_sql" > "$explain_dir/$artifact_id-estimate.json"
    "${mysql_client[@]}" --table --execute "EXPLAIN FORMAT=TRADITIONAL $query_sql" > "$explain_dir/$artifact_id-traditional.txt"
}

capture_case() {
    local case_id="$1"
    local from_value="$2"
    local offset_value="$3"

    capture_query "original-$case_id" "$(build_original_query "$from_value" "$offset_value")"
    capture_query "read-model-$case_id" "$(build_read_model_query "$from_value" "$offset_value")"
}

"${mysql_client[@]}" --table --execute "
    SHOW INDEX FROM games;
    SHOW INDEX FROM rounds;
    SHOW INDEX FROM round_scores;
    SHOW INDEX FROM game_history_read_model;
" > "$explain_dir/current-indexes.txt"

capture_case shop1_recent7d_page0 "2025-12-25 00:00:00.000000" 0
capture_case shop1_recent3mo_page0 "2025-10-01 00:00:00.000000" 0
capture_case shop1_recent3mo_page100 "2025-10-01 00:00:00.000000" 2000

echo "EXPLAIN results: $explain_dir"
