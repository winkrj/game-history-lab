#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$project_root/.gradle}"

result_id="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ ! "$result_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
    echo "Result ID must be 1-64 alphanumeric, underscore, or hyphen characters." >&2
    exit 2
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit or stash repository changes before running this retained experiment." >&2
    exit 2
fi
git_commit="$(git rev-parse HEAD)"

result_dir="benchmarks/handoff/results/$result_id"
if [[ -e "$result_dir" ]]; then
    echo "Result directory already exists: $result_dir" >&2
    exit 2
fi
mkdir -p "$result_dir"

seed_game_count="${HANDOFF_SEED_GAME_COUNT:-1000}"
if [[ ! "$seed_game_count" =~ ^[1-9][0-9]*$ ]] || (( seed_game_count < 2 || seed_game_count > 1000000 )); then
    echo "HANDOFF_SEED_GAME_COUNT must be between 2 and 1000000." >&2
    exit 2
fi

db_user="game_history"
db_password="game_history"
db_name="game_history_lab"
mysql_client=(
    docker compose exec -T
    -e "MYSQL_PWD=$db_password"
    mysql mysql
    --user="$db_user"
    --database="$db_name"
    --default-character-set=utf8mb4
)

consumer_pid=""

stop_consumer() {
    if [[ -n "$consumer_pid" ]] && kill -0 "$consumer_pid" 2>/dev/null; then
        kill "$consumer_pid"
        wait "$consumer_pid" 2>/dev/null || true
    fi
    consumer_pid=""
}

start_consumer() {
    local group_id="$1"
    local log_file="$2"

    STAGE5_GROUP_ID="$group_id" STAGE5_AUTO_OFFSET_RESET=earliest \
        ./scripts/run-stage5-consumer.sh > "$log_file" 2>&1 &
    consumer_pid=$!

    for _ in $(seq 1 120); do
        if grep -q 'partitions assigned' "$log_file" 2>/dev/null; then
            return
        fi
        if ! kill -0 "$consumer_pid" 2>/dev/null; then
            echo "Consumer exited before partition assignment: $log_file" >&2
            tail -100 "$log_file" >&2
            exit 1
        fi
        sleep 0.25
    done

    echo "Consumer did not receive a partition assignment: $log_file" >&2
    exit 1
}

wait_projection_value() {
    local game_id="$1"
    local column="$2"
    local expected="$3"
    local value=""

    for _ in $(seq 1 120); do
        value="$("${mysql_client[@]}" --batch --skip-column-names --execute \
            "SELECT $column FROM game_history_read_model WHERE game_id = $game_id" 2>/dev/null || true)"
        if [[ "$value" == "$expected" ]]; then
            return
        fi
        sleep 0.25
    done

    echo "Timed out waiting for game $game_id $column=$expected (last=$value)" >&2
    exit 1
}

games_topic_end_offset() {
    docker compose exec -T kafka /opt/kafka/bin/kafka-get-offsets.sh \
        --bootstrap-server kafka:9092 \
        --topic game-history.game_history_lab.games \
        --time -1 2>/dev/null \
        | awk -F: '{sum += $3} END {print sum + 0}'
}

wait_games_topic_offset() {
    local expected_minimum="$1"
    local current="0"

    for _ in $(seq 1 120); do
        current="$(games_topic_end_offset)"
        if (( current >= expected_minimum )); then
            printf '%s\n' "$current"
            return
        fi
        sleep 0.25
    done

    echo "Games topic did not reach end offset $expected_minimum (last=$current)." >&2
    exit 1
}

group_lag() {
    local group_id="$1"
    docker compose exec -T kafka /opt/kafka/bin/kafka-consumer-groups.sh \
        --bootstrap-server kafka:9092 \
        --group "$group_id" \
        --describe 2>/dev/null \
        | awk 'NR > 2 && $6 ~ /^[0-9]+$/ {sum += $6; found = 1} END {if (found) print sum + 0; else print -1}'
}

wait_group_caught_up() {
    local group_id="$1"
    local lag="-1"

    for _ in $(seq 1 120); do
        lag="$(group_lag "$group_id")"
        if [[ "$lag" == "0" ]]; then
            return
        fi
        sleep 0.25
    done

    echo "Consumer group $group_id did not catch up (last lag=$lag)." >&2
    exit 1
}

reset_transport_and_start_connector() {
    stop_consumer
    docker compose rm --stop --force kafka connect >/dev/null
    ./scripts/prepare-stage5-cdc.sh
}

source_status() {
    "${mysql_client[@]}" --batch --skip-column-names \
        --execute "SELECT game_status FROM games WHERE id = 1"
}

projection_status() {
    "${mysql_client[@]}" --batch --skip-column-names \
        --execute "SELECT game_status FROM game_history_read_model WHERE game_id = 1"
}

projection_mismatch_count() {
    "${mysql_client[@]}" --batch --skip-column-names --execute "
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
        SELECT COUNT(*)
        FROM source_projection source
        LEFT JOIN game_history_read_model read_model
            ON read_model.game_id = source.game_id
        WHERE read_model.game_id IS NULL
           OR read_model.shop_id <> source.shop_id
           OR read_model.played_at <> source.played_at
           OR read_model.player_nickname <> source.player_nickname
           OR read_model.course_name <> source.course_name
           OR read_model.total_score <> source.total_score
           OR read_model.round_count <> source.round_count
           OR read_model.game_status <> source.game_status;
    "
}

prepare_source() {
    SEED_GAME_COUNT="$seed_game_count" ./scripts/generate-stage1-data.sh --reset
}

run_batch() {
    local run_id="$1"
    STAGE3_SKIP_BUILD=true ./scripts/run-stage3-batch.sh \
        "$run_id" full 1 "$seed_game_count"
}

trap stop_consumer EXIT

./gradlew bootJar > "$result_dir/build.log" 2>&1

# AS-IS: a source change committed before a no-data connector starts has no CDC record.
prepare_source > "$result_dir/unsafe-seed.log" 2>&1
run_batch "handoff-unsafe-$result_id" > "$result_dir/unsafe-batch.log" 2>&1
"${mysql_client[@]}" --execute \
    "UPDATE games SET game_status = 'CANCELLED' WHERE id = 1"
reset_transport_and_start_connector > "$result_dir/unsafe-connector.log" 2>&1

# A post-start barrier proves that the connector is streaming while leaving the
# pre-start game 1 change outside its captured range.
"${mysql_client[@]}" --execute \
    "UPDATE games SET course_name = CONCAT(course_name, '-barrier') WHERE id = 2"
unsafe_end_offset="$(wait_games_topic_offset 1)"
unsafe_group="handoff-unsafe-$result_id"
start_consumer "$unsafe_group" "$result_dir/unsafe-consumer.log"
wait_projection_value 2 course_name \
    "$("${mysql_client[@]}" --batch --skip-column-names --execute \
        "SELECT course_name FROM games WHERE id = 2")"
wait_group_caught_up "$unsafe_group"
unsafe_lag="$(group_lag "$unsafe_group")"
stop_consumer

unsafe_source_status="$(source_status)"
unsafe_projection_status="$(projection_status)"
unsafe_mismatch_count="$(projection_mismatch_count)"
if [[ "$unsafe_mismatch_count" != "1" ]]; then
    echo "Unsafe control expected one mismatch but found $unsafe_mismatch_count." >&2
    exit 1
fi

# TO-BE: establish the CDC position before Batch, keep the Consumer stopped while
# Batch builds, then consume the retained change after Batch completes.
prepare_source > "$result_dir/safe-seed.log" 2>&1
reset_transport_and_start_connector > "$result_dir/safe-connector.log" 2>&1

# A captured START barrier proves the connector has established its binlog position
# before Batch begins. The Consumer remains stopped while events accumulate.
"${mysql_client[@]}" --execute \
    "UPDATE games SET course_name = CONCAT(course_name, '-start-barrier') WHERE id = 2"
safe_start_offset="$(wait_games_topic_offset 1)"
run_batch "handoff-safe-$result_id" > "$result_dir/safe-batch.log" 2>&1
"${mysql_client[@]}" --execute \
    "UPDATE games SET game_status = 'CANCELLED' WHERE id = 1"
safe_target_offset="$(wait_games_topic_offset "$((safe_start_offset + 1))")"

safe_group="handoff-safe-$result_id"
start_consumer "$safe_group" "$result_dir/safe-consumer.log"
wait_projection_value 1 game_status CANCELLED
wait_group_caught_up "$safe_group"
safe_lag="$(group_lag "$safe_group")"
stop_consumer

READ_MODEL_CHECK_SKIP_PAGES=true \
    ./scripts/check-stage2-read-model.sh > "$result_dir/safe-correctness.log" 2>&1
safe_source_status="$(source_status)"
safe_projection_status="$(projection_status)"
safe_mismatch_count="$(projection_mismatch_count)"
if [[ "$safe_mismatch_count" != "0" ]]; then
    echo "Safe handoff did not converge: mismatches=$safe_mismatch_count." >&2
    exit 1
fi

{
    printf 'scenario\tconnector_before_batch\tsource_status\tprojection_status\tmismatch\n'
    printf 'unsafe\t0\t%s\t%s\t%s\n' "$unsafe_source_status" "$unsafe_projection_status" "$unsafe_mismatch_count"
    printf 'safe\t1\t%s\t%s\t%s\n' "$safe_source_status" "$safe_projection_status" "$safe_mismatch_count"
} > "$result_dir/summary.tsv"

{
    printf 'scenario\tstart_boundary_offset\ttarget_offset\tconsumer_lag\n'
    printf 'unsafe\t0\t%s\t%s\n' "$unsafe_end_offset" "$unsafe_lag"
    printf 'safe\t%s\t%s\t%s\n' "$safe_start_offset" "$safe_target_offset" "$safe_lag"
} > "$result_dir/offsets.tsv"

{
    echo "result_id=$result_id"
    echo "completed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "git_commit=$git_commit"
    echo "seed_game_count=$seed_game_count"
    echo "snapshot_mode=no_data"
    echo "safe_order=connector-start,batch,source-change,consumer-catch-up"
} > "$result_dir/metadata.txt"

shasum -a 256 \
    scripts/run-handoff-experiment.sh \
    scripts/check-stage2-read-model.sh \
    scripts/prepare-stage5-cdc.sh \
    scripts/run-stage3-batch.sh \
    scripts/run-stage5-consumer.sh \
    config/debezium/mysql-game-history-connector.json \
    compose.yaml \
    > "$result_dir/source-manifest.sha256"

cat "$result_dir/summary.tsv"
