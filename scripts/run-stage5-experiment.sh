#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

result_id="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ ! "$result_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
    echo "Result ID must be 1-64 alphanumeric, underscore, or hyphen characters." >&2
    exit 2
fi

result_dir="benchmarks/stage5/results/$result_id"
raw_dir="$result_dir/raw"
summary_dir="$result_dir/summarized"
if [[ -e "$result_dir" ]]; then
    echo "Result directory already exists: $result_dir" >&2
    exit 2
fi
mkdir -p "$raw_dir" "$summary_dir"

db_user="${STAGE5_DB_USERNAME:-game_history}"
db_password="${STAGE5_DB_PASSWORD:-game_history}"
db_name="${STAGE5_DB_NAME:-game_history_lab}"
mysql_client=(
    docker compose exec -T
    -e "MYSQL_PWD=$db_password"
    mysql mysql
    --user="$db_user"
    --database="$db_name"
    --default-character-set=utf8mb4
)

epoch_ms() {
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

status_value() {
    local name="$1"
    "${mysql_client[@]}" --batch --skip-column-names \
        --execute "SHOW GLOBAL STATUS LIKE '$name'" | awk '{print $2}'
}

start_consumer() {
    local group_id="$1"
    local fail_game_id="$2"
    local auto_offset_reset="$3"
    local log_file="$4"
    STAGE5_GROUP_ID="$group_id" STAGE5_FAIL_ON_GAME_ID="$fail_game_id" \
        STAGE5_AUTO_OFFSET_RESET="$auto_offset_reset" \
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

stop_consumer() {
    if [[ -n "${consumer_pid:-}" ]] && kill -0 "$consumer_pid" 2>/dev/null; then
        kill "$consumer_pid"
        wait "$consumer_pid" 2>/dev/null || true
    fi
    consumer_pid=""
}

wait_projection_value() {
    local game_id="$1"
    local column="$2"
    local expected="$3"
    local deadline=$(( $(epoch_ms) + 15000 ))
    local value
    while (( $(epoch_ms) < deadline )); do
        value="$("${mysql_client[@]}" --batch --skip-column-names --execute \
            "SELECT $column FROM game_history_read_model WHERE game_id = $game_id" 2>/dev/null || true)"
        if [[ "$value" == "$expected" ]]; then
            epoch_ms
            return
        fi
        sleep 0.02
    done
    echo "Timed out waiting for game $game_id $column=$expected (last=$value)" >&2
    exit 1
}

group_offsets() {
    local group_id="$1"
    docker compose exec -T kafka /opt/kafka/bin/kafka-consumer-groups.sh \
        --bootstrap-server kafka:9092 --group "$group_id" --describe 2>&1 || true
}

trap stop_consumer EXIT

./scripts/prepare-stage5-cdc.sh > "$raw_dir/prepare.log" 2>&1
./gradlew bootJar > "$raw_dir/build.log" 2>&1

# Every run keeps its few rows so an earliest-offset replay can still resolve parents.
# The ID is derived from UTC epoch seconds and is never reused by the deterministic 1M seed.
base_id=$((5000000000 + $(date -u +%s)))
main_game_id=$base_id
failure_game_id=$((base_id + 1))
round_one_id=$((base_id * 10))
round_two_id=$((base_id * 10 + 1))
score_one_id=$((base_id * 10))
score_two_id=$((base_id * 10 + 1))
main_group="stage5-main-$result_id"
failure_group="stage5-failure-$result_id"
replay_group="stage5-replay-$result_id"

hardware_info="$(system_profiler SPHardwareDataType | awk -F: '
    /Chip|Total Number of Cores|Memory/ {
        gsub(/^ +/, "", $2)
        printf "%s=%s;", $1, $2
    }
')"
source_counts_sql="
    SELECT
        (SELECT COUNT(*) FROM shops) AS shops,
        (SELECT COUNT(*) FROM games) AS games,
        (SELECT COUNT(*) FROM rounds) AS rounds,
        (SELECT COUNT(*) FROM round_scores) AS round_scores,
        (SELECT COUNT(*) FROM game_history_read_model) AS read_model_rows;
"
{
    echo "result_id=$result_id"
    echo "started_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "git_commit=$(git rev-parse HEAD)"
    echo "git_status_begin"
    git status --short
    echo "git_status_end"
    echo "tracked_diff_sha256=$(git diff --binary | shasum -a 256 | awk '{print $1}')"
    echo "jar_sha256=$(shasum -a 256 build/libs/game-history-lab-0.0.1-SNAPSHOT.jar | awk '{print $1}')"
    echo "java_version=$(java -version 2>&1 | head -1)"
    echo "docker_version=$(docker version --format '{{.Server.Version}}')"
    echo "mysql_version=$("${mysql_client[@]}" --batch --skip-column-names --execute 'SELECT VERSION()')"
    echo "kafka_image=apache/kafka:4.1.1"
    echo "debezium_image=quay.io/debezium/connect:3.4.3.Final"
    echo "os=$(sw_vers | tr '\n' ';')"
    echo "hardware=$hardware_info"
    echo "dataset_seed=20260810"
    echo "dataset_before"
    "${mysql_client[@]}" --batch --raw --execute "$source_counts_sql"
    echo "dataset_before_end"
    echo "main_game_id=$main_game_id"
    echo "failure_game_id=$failure_game_id"
    echo "commands=./scripts/prepare-stage5-cdc.sh; ./scripts/run-stage5-experiment.sh $result_id"
} > "$result_dir/metadata.txt"

find build.gradle.kts settings.gradle.kts compose.yaml config src/main src/test scripts \
    -type f -print0 | sort -z | xargs -0 shasum -a 256 > "$result_dir/source-manifest.sha256"
curl --fail --silent http://localhost:8083/connectors/game-history-mysql/status \
    > "$raw_dir/connector-status.json"
docker compose ps > "$raw_dir/compose-ps.txt"
docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server kafka:9092 --describe > "$raw_dir/topics.txt"
docker stats --no-stream > "$raw_dir/docker-stats-before.txt"

consumer_pid=""
start_consumer "$main_group" 0 latest "$raw_dir/main-consumer.log"

# Idle cost: no Source mutation and no application polling job. MySQL Questions still
# includes health checks, Debezium metadata/binlog work, and this script's own samples.
idle_questions_before="$(status_value Questions)"
sleep 10
idle_questions_after="$(status_value Questions)"
printf 'duration_seconds\tquestions_delta\n10\t%s\n' \
    "$((idle_questions_after - idle_questions_before))" > "$summary_dir/idle-cost.tsv"

echo -e "scenario\tcommit_observed_ms\tvisible_ms\tlag_ms" > "$summary_dir/correctness-freshness.tsv"
run_scenario() {
    local scenario="$1"
    local sql="$2"
    local game_id="$3"
    local column="$4"
    local expected="$5"
    "${mysql_client[@]}" --execute "$sql"
    local committed_at
    local visible_at
    committed_at="$(epoch_ms)"
    visible_at="$(wait_projection_value "$game_id" "$column" "$expected")"
    echo -e "$scenario\t$committed_at\t$visible_at\t$((visible_at - committed_at))" \
        >> "$summary_dir/correctness-freshness.tsv"
}

change_questions_before="$(status_value Questions)"
run_scenario new-game "
    START TRANSACTION;
    INSERT INTO games (id, shop_id, played_at, player_nickname, course_name, game_status)
    VALUES ($main_game_id, 1, '2026-08-13 09:00:00.000000', 'stage5-player', 'Stage5 Course', 'IN_PROGRESS');
    INSERT INTO rounds (id, game_id, round_number) VALUES ($round_one_id, $main_game_id, 1);
    INSERT INTO round_scores (id, round_id, score) VALUES ($score_one_id, $round_one_id, 10);
    COMMIT;
" "$main_game_id" total_score 10
run_scenario status-update \
    "UPDATE games SET game_status = 'COMPLETED' WHERE id = $main_game_id" \
    "$main_game_id" game_status COMPLETED
run_scenario round-insert "
    INSERT INTO rounds (id, game_id, round_number) VALUES ($round_two_id, $main_game_id, 2)
" "$main_game_id" round_count 2
run_scenario score-update "
    START TRANSACTION;
    INSERT INTO round_scores (id, round_id, score) VALUES ($score_two_id, $round_two_id, 20);
    UPDATE round_scores SET score = 25 WHERE id = $score_two_id;
    COMMIT;
" "$main_game_id" total_score 35

# Same-game rapid ordering: table topics have no global order, so only final convergence
# is asserted. Each event re-reads the latest committed Source state.
run_scenario ordered-final "
    START TRANSACTION;
    UPDATE games SET game_status = 'IN_PROGRESS' WHERE id = $main_game_id;
    UPDATE games SET game_status = 'COMPLETED' WHERE id = $main_game_id;
    UPDATE round_scores SET score = 30 WHERE id = $score_two_id;
    COMMIT;
" "$main_game_id" total_score 40

echo -e "sample\texpected_status\tcommit_observed_ms\tvisible_ms\tlag_ms" \
    > "$summary_dir/freshness-samples.tsv"
for sample in $(seq 1 20); do
    if (( sample % 2 == 0 )); then
        expected_status="COMPLETED"
    else
        expected_status="IN_PROGRESS"
    fi
    "${mysql_client[@]}" --execute \
        "UPDATE games SET game_status = '$expected_status' WHERE id = $main_game_id"
    committed_at="$(epoch_ms)"
    visible_at="$(wait_projection_value "$main_game_id" game_status "$expected_status")"
    echo -e "$sample\t$expected_status\t$committed_at\t$visible_at\t$((visible_at - committed_at))" \
        >> "$summary_dir/freshness-samples.tsv"
done
change_questions_after="$(status_value Questions)"
printf 'scenarios\tfreshness_samples\tquestions_delta\n5\t20\t%s\n' \
    "$((change_questions_after - change_questions_before))" > "$summary_dir/change-cost.tsv"

# Stop the normal consumer, then prove DB rollback + uncommitted offset + redelivery.
stop_consumer
start_consumer "$failure_group" "$failure_game_id" latest "$raw_dir/failure-consumer.log"
failure_offset_before="$(group_offsets "$failure_group")"
printf '%s\n' "$failure_offset_before" > "$raw_dir/failure-offset-before.txt"
"${mysql_client[@]}" --execute "
    INSERT INTO games (id, shop_id, played_at, player_nickname, course_name, game_status)
    VALUES ($failure_game_id, 1, '2026-08-13 09:01:00.000000', 'stage5-failure', 'Stage5 Course', 'COMPLETED');
"
for _ in $(seq 1 120); do
    grep -q 'Deterministic CDC failure' "$raw_dir/failure-consumer.log" && break
    sleep 0.25
done
grep -q 'Deterministic CDC failure' "$raw_dir/failure-consumer.log"
failure_rm_rows="$("${mysql_client[@]}" --batch --skip-column-names --execute \
    "SELECT COUNT(*) FROM game_history_read_model WHERE game_id = $failure_game_id")"
printf 'game_id\tread_model_rows_after_failure\n%s\t%s\n' \
    "$failure_game_id" "$failure_rm_rows" > "$raw_dir/failure-state.tsv"
[[ "$failure_rm_rows" == "0" ]]
group_offsets "$failure_group" > "$raw_dir/failure-offset-after.txt"
stop_consumer

start_consumer "$failure_group" 0 latest "$raw_dir/restart-consumer.log"
restart_visible_at="$(wait_projection_value "$failure_game_id" game_status COMPLETED)"
echo "restart_visible_at_ms=$restart_visible_at" >> "$raw_dir/restart-consumer.log"
group_offsets "$failure_group" > "$raw_dir/restart-offset-after.txt"
stop_consumer

# Replay all retained CDC records with a fresh earliest group. Full-row UPSERT must leave
# the tracked projection checksum and exhaustive Source equality unchanged.
checksum_sql="
    SELECT COALESCE(SUM(CRC32(CONCAT_WS('|', game_id, shop_id, played_at,
        player_nickname, course_name, total_score, round_count, game_status))), 0)
    FROM game_history_read_model
    WHERE game_id IN ($main_game_id, $failure_game_id);
"
checksum_before="$("${mysql_client[@]}" --batch --skip-column-names --execute "$checksum_sql")"
start_consumer "$replay_group" 0 earliest "$raw_dir/replay-consumer.log"
for _ in $(seq 1 120); do
    lag="$(group_offsets "$replay_group" | awk 'NR > 2 && $6 ~ /^[0-9]+$/ {sum += $6} END {print sum + 0}')"
    replay_count="$(grep -c 'STAGE5_CDC_APPLIED' "$raw_dir/replay-consumer.log" || true)"
    [[ "$lag" == "0" && "$replay_count" -gt 0 ]] && break
    sleep 0.25
done
group_offsets "$replay_group" > "$raw_dir/replay-offset-after.txt"
replay_count="$(grep -c 'STAGE5_CDC_APPLIED' "$raw_dir/replay-consumer.log" || true)"
[[ "$replay_count" -gt 0 && "$lag" == "0" ]]
stop_consumer
checksum_after="$("${mysql_client[@]}" --batch --skip-column-names --execute "$checksum_sql")"
printf 'records_applied\tchecksum_before\tchecksum_after\tequal\n%s\t%s\t%s\t%s\n' \
    "$replay_count" "$checksum_before" "$checksum_after" "$([[ "$checksum_before" == "$checksum_after" ]] && echo 1 || echo 0)" \
    > "$summary_dir/replay.tsv"
[[ "$checksum_before" == "$checksum_after" ]]

./scripts/check-stage2-read-model.sh > "$raw_dir/final-source-read-model-check.log" 2>&1
docker stats --no-stream > "$raw_dir/docker-stats-after.txt"
"${mysql_client[@]}" --batch --raw --execute "$source_counts_sql" \
    > "$raw_dir/dataset-after.tsv"

awk -F '\t' 'NR > 1 {print $5}' "$summary_dir/freshness-samples.tsv" | sort -n \
    > "$summary_dir/freshness-lag-ms.sorted"
sample_count="$(wc -l < "$summary_dir/freshness-lag-ms.sorted" | tr -d ' ')"
p50_rank=$(( (sample_count * 50 + 99) / 100 ))
p95_rank=$(( (sample_count * 95 + 99) / 100 ))
p50="$(sed -n "${p50_rank}p" "$summary_dir/freshness-lag-ms.sorted")"
p95="$(sed -n "${p95_rank}p" "$summary_dir/freshness-lag-ms.sorted")"
max="$(tail -1 "$summary_dir/freshness-lag-ms.sorted")"
printf 'samples\tp50_ms\tp95_ms\tmax_ms\tmissing\n%s\t%s\t%s\t%s\t0\n' \
    "$sample_count" "$p50" "$p95" "$max" > "$summary_dir/freshness-summary.tsv"

{
    echo "completed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat "$summary_dir/freshness-summary.tsv"
    cat "$summary_dir/idle-cost.tsv"
    cat "$summary_dir/change-cost.tsv"
    cat "$summary_dir/replay.tsv"
} > "$summary_dir/result.txt"

echo "Stage 5 experiment completed: $result_dir"
cat "$summary_dir/result.txt"
