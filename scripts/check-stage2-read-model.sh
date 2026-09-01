#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

read_model_db_user="${READ_MODEL_DB_USERNAME:-game_history}"
read_model_db_password="${READ_MODEL_DB_PASSWORD:-game_history}"
read_model_db_name="${READ_MODEL_DB_NAME:-game_history_lab}"
skip_representative_pages="${READ_MODEL_CHECK_SKIP_PAGES:-false}"

if [[ "$skip_representative_pages" != "true" && "$skip_representative_pages" != "false" ]]; then
    echo "READ_MODEL_CHECK_SKIP_PAGES must be true or false." >&2
    exit 2
fi

mysql_client=(
    docker compose exec -T
    -e "MYSQL_PWD=$read_model_db_password"
    mysql mysql
    --user="$read_model_db_user"
    --database="$read_model_db_name"
    --default-character-set=utf8mb4
)

verification="$("${mysql_client[@]}" --batch --skip-column-names --execute "
    WITH source_projection AS (
        SELECT
            g.id AS game_id,
            g.shop_id,
            g.played_at,
            g.player_nickname,
            g.course_name,
            COALESCE(SUM(rs.score), 0) AS total_score,
            COUNT(DISTINCT r.id) AS round_count,
            g.game_status
        FROM games g
        LEFT JOIN rounds r ON r.game_id = g.id
        LEFT JOIN round_scores rs ON rs.round_id = r.id
        GROUP BY
            g.id,
            g.shop_id,
            g.played_at,
            g.player_nickname,
            g.course_name,
            g.game_status
    )
    SELECT
        (SELECT COUNT(*) FROM games),
        (SELECT COUNT(*) FROM game_history_read_model),
        (SELECT COUNT(*)
         FROM source_projection source
         LEFT JOIN game_history_read_model read_model ON read_model.game_id = source.game_id
         WHERE read_model.game_id IS NULL
            OR read_model.shop_id <> source.shop_id
            OR read_model.played_at <> source.played_at
            OR read_model.player_nickname <> source.player_nickname
            OR read_model.course_name <> source.course_name
            OR read_model.total_score <> source.total_score
            OR read_model.round_count <> source.round_count
            OR read_model.game_status <> source.game_status),
        (SELECT COUNT(*)
         FROM game_history_read_model read_model
         LEFT JOIN games game ON game.id = read_model.game_id
         WHERE game.id IS NULL);
")"
verification="${verification//$'\r'/}"

IFS=$'\t' read -r source_rows read_model_rows mismatched_rows extra_rows <<< "$verification"

if [[ "$source_rows" != "$read_model_rows" ]]; then
    echo "Source/Read Model count mismatch: source=$source_rows read_model=$read_model_rows." >&2
    exit 1
fi
if [[ "$mismatched_rows" != "0" ]]; then
    echo "Found $mismatched_rows Read Model rows that differ from the Source projection." >&2
    exit 1
fi
if [[ "$extra_rows" != "0" ]]; then
    echo "Found $extra_rows Read Model rows without a Source game." >&2
    exit 1
fi

original_page() {
    local from_value="$1"
    local offset_value="$2"

    "${mysql_client[@]}" --batch --skip-column-names --raw --execute "
        SELECT
            g.id,
            s.id,
            DATE_FORMAT(g.played_at, '%Y-%m-%d %H:%i:%s.%f'),
            g.player_nickname,
            g.course_name,
            COALESCE(SUM(rs.score), 0),
            COUNT(DISTINCT r.id),
            g.game_status
        FROM games g
        JOIN shops s ON s.id = g.shop_id
        LEFT JOIN rounds r ON r.game_id = g.id
        LEFT JOIN round_scores rs ON rs.round_id = r.id
        WHERE s.id = 1
          AND g.played_at >= '$from_value'
          AND g.played_at < '2026-01-01 00:00:00.000000'
        GROUP BY
            g.id,
            s.id,
            g.played_at,
            g.player_nickname,
            g.course_name,
            g.game_status
        ORDER BY g.played_at DESC, g.id DESC
        LIMIT 20 OFFSET $offset_value;
    "
}

read_model_page() {
    local from_value="$1"
    local offset_value="$2"

    "${mysql_client[@]}" --batch --skip-column-names --raw --execute "
        SELECT
            game_id,
            shop_id,
            DATE_FORMAT(played_at, '%Y-%m-%d %H:%i:%s.%f'),
            player_nickname,
            course_name,
            total_score,
            round_count,
            game_status
        FROM game_history_read_model
        WHERE shop_id = 1
          AND played_at >= '$from_value'
          AND played_at < '2026-01-01 00:00:00.000000'
        ORDER BY played_at DESC, game_id DESC
        LIMIT 20 OFFSET $offset_value;
    "
}

compare_page() {
    local case_id="$1"
    local from_value="$2"
    local offset_value="$3"
    local original_result
    local read_model_result

    original_result="$(original_page "$from_value" "$offset_value")"
    read_model_result="$(read_model_page "$from_value" "$offset_value")"
    if [[ "$original_result" != "$read_model_result" ]]; then
        echo "Representative query mismatch: $case_id." >&2
        exit 1
    fi
    if [[ "$(printf '%s\n' "$read_model_result" | sed '/^$/d' | wc -l | tr -d ' ')" != "20" ]]; then
        echo "Representative query did not return 20 rows: $case_id." >&2
        exit 1
    fi
}

if [[ "$skip_representative_pages" == "false" ]]; then
    compare_page "shop1_recent7d_page0" "2025-12-25 00:00:00.000000" 0
    compare_page "shop1_recent3mo_page0" "2025-10-01 00:00:00.000000" 0
    compare_page "shop1_recent3mo_page100" "2025-10-01 00:00:00.000000" 2000
fi

"${mysql_client[@]}" --table --execute "
    SELECT 'source_games' AS metric, COUNT(*) AS value FROM games
    UNION ALL
    SELECT 'read_model_rows', COUNT(*) FROM game_history_read_model
    UNION ALL
    SELECT 'popular_shop_1_rows', COUNT(*) FROM game_history_read_model WHERE shop_id = 1;
"

if [[ "$skip_representative_pages" == "true" ]]; then
    echo "Read Model verification passed: all $read_model_rows rows match the Source projection."
else
    echo "Stage 2 Read Model verification passed: all $read_model_rows rows and three representative pages match the Source projection."
fi
