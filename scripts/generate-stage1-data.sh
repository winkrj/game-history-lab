#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

seed_game_count="${SEED_GAME_COUNT:-1000000}"
seed_value="${SEED_VALUE:-20260810}"
seed_db_user="${SEED_DB_USERNAME:-game_history}"
seed_db_password="${SEED_DB_PASSWORD:-game_history}"
seed_db_name="${SEED_DB_NAME:-game_history_lab}"
reset_requested=false

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

if [[ "${1:-}" == "--reset" ]]; then
    reset_requested=true
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--reset]" >&2
    exit 2
fi

if ! is_decimal_at_most "$seed_game_count" "1000000"; then
    echo "SEED_GAME_COUNT must be an integer between 1 and 1000000." >&2
    exit 2
fi
seed_game_count="$(normalize_decimal "$seed_game_count")"
if [[ "$seed_game_count" == "0" ]]; then
    echo "SEED_GAME_COUNT must be an integer between 1 and 1000000." >&2
    exit 2
fi

if ! is_decimal_at_most "$seed_value" "2147483647"; then
    echo "SEED_VALUE must be an integer between 0 and 2147483647." >&2
    exit 2
fi
seed_value="$(normalize_decimal "$seed_value")"

docker compose up -d --wait mysql

mysql_client=(
    docker compose exec -T
    -e "MYSQL_PWD=$seed_db_password"
    mysql mysql
    --user="$seed_db_user"
    --database="$seed_db_name"
    --default-character-set=utf8mb4
)

"${mysql_client[@]}" < src/main/resources/schema.sql

existing_source_rows="$(
    "${mysql_client[@]}" --batch --skip-column-names --execute "
        SELECT
            (SELECT COUNT(*) FROM shops)
            + (SELECT COUNT(*) FROM games)
            + (SELECT COUNT(*) FROM rounds)
            + (SELECT COUNT(*) FROM round_scores);
    "
)"
existing_source_rows="${existing_source_rows//$'\r'/}"

if (( existing_source_rows > 0 )) && [[ "$reset_requested" != true ]]; then
    echo "Source tables already contain data. Re-run with --reset to replace it." >&2
    exit 1
fi

echo "Generating deterministic Stage 1 data: games=$seed_game_count seed=$seed_value"
{
    printf 'SET @game_count = %s;\n' "$seed_game_count"
    printf 'SET @seed = %s;\n' "$seed_value"
    sed -n '1,$p' src/main/resources/stage1-seed.sql
} | "${mysql_client[@]}"

SEED_GAME_COUNT="$seed_game_count" \
SEED_VALUE="$seed_value" \
SEED_DB_USERNAME="$seed_db_user" \
SEED_DB_PASSWORD="$seed_db_password" \
SEED_DB_NAME="$seed_db_name" \
    ./scripts/check-stage1-data.sh
