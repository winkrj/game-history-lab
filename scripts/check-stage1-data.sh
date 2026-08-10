#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

expected_game_count="${SEED_GAME_COUNT:-1000000}"
seed_db_user="${SEED_DB_USERNAME:-game_history}"
seed_db_password="${SEED_DB_PASSWORD:-game_history}"
seed_db_name="${SEED_DB_NAME:-game_history_lab}"
seed_value="${SEED_VALUE:-20260810}"

normalize_decimal() {
    local value="$1"
    while [[ ${#value} -gt 1 && "${value:0:1}" == "0" ]]; do
        value="${value:1}"
    done
    printf '%s' "$value"
}

is_decimal_at_most() {
    local value="$1"
    local maximum="$2"

    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    value="$(normalize_decimal "$value")"
    (( ${#value} < ${#maximum} )) && return 0
    (( ${#value} == ${#maximum} )) && [[ "$value" < "$maximum" || "$value" == "$maximum" ]]
}

if ! is_decimal_at_most "$expected_game_count" "1000000"; then
    echo "SEED_GAME_COUNT must be an integer between 1 and 1000000." >&2
    exit 2
fi
expected_game_count="$(normalize_decimal "$expected_game_count")"
if [[ "$expected_game_count" == "0" ]]; then
    echo "SEED_GAME_COUNT must be an integer between 1 and 1000000." >&2
    exit 2
fi

if ! is_decimal_at_most "$seed_value" "2147483647"; then
    echo "SEED_VALUE must be an integer between 0 and 2147483647." >&2
    exit 2
fi
seed_value="$(normalize_decimal "$seed_value")"

mysql_client=(
    docker compose exec -T
    -e "MYSQL_PWD=$seed_db_password"
    mysql mysql
    --user="$seed_db_user"
    --database="$seed_db_name"
    --default-character-set=utf8mb4
)

seed_summary="$(
    "${mysql_client[@]}" --batch --skip-column-names --execute "
        SELECT
            (SELECT COUNT(*) FROM shops),
            (SELECT COUNT(*) FROM games),
            (SELECT COUNT(*) FROM rounds),
            (SELECT COUNT(*) FROM round_scores),
            (SELECT COALESCE(SUM(CASE
                WHEN MOD(FLOOR((id - 1) / 10) + $seed_value, 20) = 0 THEN 0
                WHEN MOD(FLOOR((id - 1) / 10) + $seed_value, 20) IN (1, 2) THEN 2
                ELSE 4
            END), 0) FROM games),
            (SELECT COALESCE(SUM(CASE
                WHEN MOD(FLOOR((id - 1) / 10) + $seed_value, 20) = 0 THEN 0
                WHEN MOD(FLOOR((id - 1) / 10) + $seed_value, 20) IN (1, 2) THEN 1
                ELSE 8
            END), 0) FROM games),
            (SELECT COUNT(*) FROM games game LEFT JOIN shops shop ON shop.id = game.shop_id WHERE shop.id IS NULL)
                + (SELECT COUNT(*) FROM rounds round_row LEFT JOIN games game ON game.id = round_row.game_id WHERE game.id IS NULL)
                + (SELECT COUNT(*) FROM round_scores score LEFT JOIN rounds round_row ON round_row.id = score.round_id WHERE round_row.id IS NULL),
            (SELECT COUNT(*) FROM games WHERE shop_id = 1),
            (SELECT COUNT(*) FROM games WHERE shop_id = 2),
            (SELECT COUNT(*) FROM games WHERE id < 1 OR id > $expected_game_count),
            (SELECT COUNT(*) FROM games WHERE
                shop_id <> CASE
                    WHEN MOD((id - 1) + $seed_value, 10) = 0 THEN 1
                    ELSE 2 + MOD((id - 1) * 37 + $seed_value, 99)
                END
                OR game_status <> CASE
                    WHEN MOD(FLOOR((id - 1) / 10) + $seed_value, 20) = 0 THEN 'CANCELLED'
                    WHEN MOD(FLOOR((id - 1) / 10) + $seed_value, 20) IN (1, 2) THEN 'IN_PROGRESS'
                    ELSE 'COMPLETED'
                END
                OR played_at <> DATE_ADD(
                    '2025-01-01 00:00:00',
                    INTERVAL MOD((id - 1) * 104729 + $seed_value, 31536000) SECOND
                )
                OR player_nickname <> CONCAT('player-', LPAD(MOD((id - 1) * 17 + $seed_value, 200000), 6, '0'))
                OR course_name <> CONCAT('course-', LPAD(MOD((id - 1) * 13 + $seed_value, 20) + 1, 2, '0'))),
            (SELECT COUNT(*) FROM rounds round_row
             JOIN games game ON game.id = round_row.game_id
             WHERE round_row.id <> (game.id - 1) * 4 + round_row.round_number
                OR round_row.round_number < 1
                OR round_row.round_number > CASE
                    WHEN MOD(FLOOR((game.id - 1) / 10) + $seed_value, 20) = 0 THEN 0
                    WHEN MOD(FLOOR((game.id - 1) / 10) + $seed_value, 20) IN (1, 2) THEN 2
                    ELSE 4
                END),
            (SELECT COUNT(*) FROM round_scores score_row
             JOIN rounds round_row ON round_row.id = score_row.round_id
             JOIN games game ON game.id = round_row.game_id
             WHERE score_row.id NOT IN ((round_row.id - 1) * 2 + 1, (round_row.id - 1) * 2 + 2)
                OR (game.game_status = 'IN_PROGRESS'
                    AND (round_row.round_number <> 1 OR score_row.id <> (round_row.id - 1) * 2 + 1))
                OR game.game_status = 'CANCELLED'
                OR score_row.score <> MOD(
                    round_row.id * 31
                        + (score_row.id - (round_row.id - 1) * 2) * 7
                        + $seed_value,
                    11
                ) - 5);
    "
)"
seed_summary="${seed_summary//$'\r'/}"

IFS=$'\t' read -r \
    actual_shop_count \
    actual_game_count \
    actual_round_count \
    actual_score_count \
    expected_round_count \
    expected_score_count \
    orphan_count \
    popular_shop_count \
    typical_shop_count \
    invalid_game_id_count \
    invalid_game_shape_count \
    invalid_round_shape_count \
    invalid_score_shape_count <<< "$seed_summary"

if [[ "$actual_shop_count" != "100" ]]; then
    echo "Expected 100 shops but found $actual_shop_count." >&2
    exit 1
fi
if [[ "$actual_game_count" != "$expected_game_count" ]]; then
    echo "Expected $expected_game_count games but found $actual_game_count." >&2
    exit 1
fi
if [[ "$actual_round_count" != "$expected_round_count" ]]; then
    echo "Expected $expected_round_count rounds but found $actual_round_count." >&2
    exit 1
fi
if [[ "$actual_score_count" != "$expected_score_count" ]]; then
    echo "Expected $expected_score_count round scores but found $actual_score_count." >&2
    exit 1
fi
if [[ "$orphan_count" != "0" ]]; then
    echo "Found $orphan_count orphan Source rows." >&2
    exit 1
fi
if [[ "$invalid_game_id_count" != "0" ]]; then
    echo "Found $invalid_game_id_count games outside the expected ID range." >&2
    exit 1
fi
if [[ "$invalid_game_shape_count" != "0" ]]; then
    echo "Found $invalid_game_shape_count games that do not match the deterministic seed mapping." >&2
    exit 1
fi
if [[ "$invalid_round_shape_count" != "0" ]]; then
    echo "Found $invalid_round_shape_count rounds that do not match the expected game shape." >&2
    exit 1
fi
if [[ "$invalid_score_shape_count" != "0" ]]; then
    echo "Found $invalid_score_shape_count round scores that do not match the expected round shape." >&2
    exit 1
fi
if (( expected_game_count >= 100 && popular_shop_count <= typical_shop_count )); then
    echo "Popular shop skew is missing: shop1=$popular_shop_count shop2=$typical_shop_count." >&2
    exit 1
fi

"${mysql_client[@]}" --table --execute "
    SELECT 'shops' AS metric, COUNT(*) AS value FROM shops
    UNION ALL SELECT 'games', COUNT(*) FROM games
    UNION ALL SELECT 'rounds', COUNT(*) FROM rounds
    UNION ALL SELECT 'round_scores', COUNT(*) FROM round_scores
    UNION ALL SELECT 'popular_shop_1_games', COUNT(*) FROM games WHERE shop_id = 1
    UNION ALL SELECT 'typical_shop_2_games', COUNT(*) FROM games WHERE shop_id = 2;

    SELECT MIN(played_at) AS first_played_at, MAX(played_at) AS last_played_at
    FROM games;
"

echo "Stage 1 data verification passed."
