#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

stage3_result_id="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
stage3_result_dir="benchmarks/stage3/results/$stage3_result_id"
stage3_raw_dir="$stage3_result_dir/raw"
stage3_summary_dir="$stage3_result_dir/summarized"
stage3_db_user="${STAGE3_DB_USERNAME:-game_history}"
stage3_db_password="${STAGE3_DB_PASSWORD:-game_history}"
stage3_db_name="${STAGE3_DB_NAME:-game_history_lab}"

if [[ ! "$stage3_result_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
    echo "Result ID must be 1-64 alphanumeric, underscore, or hyphen characters." >&2
    exit 2
fi

if [[ -e "$stage3_result_dir" ]]; then
    echo "Result directory already exists: $stage3_result_dir" >&2
    exit 2
fi

mkdir -p "$stage3_raw_dir" "$stage3_summary_dir"
docker compose up -d --wait mysql
./gradlew bootJar

mysql_client=(
    docker compose exec -T
    -e "MYSQL_PWD=$stage3_db_password"
    mysql mysql
    --user="$stage3_db_user"
    --database="$stage3_db_name"
    --default-character-set=utf8mb4
)

source_counts_sql="
    SELECT
        (SELECT COUNT(*) FROM shops) AS shops,
        (SELECT COUNT(*) FROM games) AS games,
        (SELECT COUNT(*) FROM rounds) AS rounds,
        (SELECT COUNT(*) FROM round_scores) AS round_scores,
        (SELECT COUNT(*) FROM game_history_read_model) AS read_model_rows;
"

{
    echo "result_id=$stage3_result_id"
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
    echo "os=$(sw_vers | tr '\n' ';')"
    echo "hardware=$(system_profiler SPHardwareDataType | awk -F: '/Chip|Total Number of Cores|Memory/ {gsub(/^ +/, "", $2); printf "%s=%s;", $1, $2}')"
    echo "dataset_seed=20260810"
    echo "chunk_size=1000"
    echo "failure_game_id=250001"
    echo "partial_range=400001..410000"
    echo "commands=simple rebuild; killed simple rebuild; batch full; batch failure; same-instance restart; range backfill"
    "${mysql_client[@]}" --batch --raw --execute "$source_counts_sql"
} > "$stage3_result_dir/metadata.txt"

find build.gradle.kts settings.gradle.kts src/main src/test scripts \
    -type f -print0 | sort -z | xargs -0 shasum -a 256 > "$stage3_result_dir/source-manifest.sha256"

{
    echo "command=./scripts/rebuild-stage2-read-model.sh"
    /usr/bin/time -p ./scripts/rebuild-stage2-read-model.sh
} > "$stage3_raw_dir/simple-full.log" 2>&1

set +e
"${mysql_client[@]}" --verbose < src/main/resources/stage2-rebuild-read-model.sql \
    > "$stage3_raw_dir/simple-failure.log" 2>&1 &
simple_failure_pid=$!
set -e

simple_connection_id=""
for _ in $(seq 1 200); do
    simple_connection_id="$("${mysql_client[@]}" --batch --skip-column-names --execute "
        SELECT ID
        FROM information_schema.PROCESSLIST
        WHERE DB = '$stage3_db_name'
          AND COMMAND = 'Query'
          AND INFO LIKE 'INSERT INTO game_history_read_model%'
        ORDER BY TIME DESC
        LIMIT 1;
    ")"
    simple_connection_id="${simple_connection_id//$'\r'/}"
    if [[ -n "$simple_connection_id" ]]; then
        break
    fi
    sleep 0.1
done

if [[ -z "$simple_connection_id" ]]; then
    kill "$simple_failure_pid" 2>/dev/null || true
    wait "$simple_failure_pid" 2>/dev/null || true
    echo "Could not locate the simple rebuild INSERT for failure injection." >&2
    exit 1
fi

"${mysql_client[@]}" --execute "KILL QUERY $simple_connection_id"
set +e
wait "$simple_failure_pid"
simple_failure_exit=$?
set -e
simple_failure_rows="$("${mysql_client[@]}" --batch --skip-column-names --execute \
    "SELECT COUNT(*) FROM game_history_read_model")"
{
    echo "client_exit=$simple_failure_exit"
    echo "killed_connection_id=$simple_connection_id"
    echo "read_model_rows_after_failure=$simple_failure_rows"
} >> "$stage3_raw_dir/simple-failure.log"

if [[ "$simple_failure_exit" == "0" || "$simple_failure_rows" != "0" ]]; then
    echo "Simple failure did not leave the expected failed/empty state." >&2
    exit 1
fi

batch_full_run_id="stage3-full-$stage3_result_id"
{
    echo "command=./scripts/run-stage3-batch.sh $batch_full_run_id full 1 1000000"
    /usr/bin/time -p env STAGE3_SKIP_BUILD=true \
        ./scripts/run-stage3-batch.sh "$batch_full_run_id" full 1 1000000
} > "$stage3_raw_dir/batch-full.log" 2>&1
./scripts/check-stage2-read-model.sh > "$stage3_raw_dir/batch-full-correctness.log" 2>&1

"${mysql_client[@]}" --execute "TRUNCATE TABLE game_history_read_model"
batch_restart_run_id="stage3-restart-$stage3_result_id"
set +e
{
    echo "command=./scripts/run-stage3-batch.sh $batch_restart_run_id full 1 1000000 250001"
    /usr/bin/time -p env STAGE3_SKIP_BUILD=true \
        ./scripts/run-stage3-batch.sh "$batch_restart_run_id" full 1 1000000 250001
} > "$stage3_raw_dir/batch-failure.log" 2>&1
batch_failure_exit=$?
set -e
batch_failure_rows="$("${mysql_client[@]}" --batch --skip-column-names --execute \
    "SELECT COUNT(*) FROM game_history_read_model")"
{
    echo "client_exit=$batch_failure_exit"
    echo "read_model_rows_after_failure=$batch_failure_rows"
} >> "$stage3_raw_dir/batch-failure.log"

if [[ "$batch_failure_exit" == "0" || "$batch_failure_rows" != "250000" ]]; then
    echo "Batch failure did not stop after the expected committed chunk." >&2
    exit 1
fi

{
    echo "command=./scripts/run-stage3-batch.sh $batch_restart_run_id full 1 1000000 0"
    /usr/bin/time -p env STAGE3_SKIP_BUILD=true \
        ./scripts/run-stage3-batch.sh "$batch_restart_run_id" full 1 1000000 0
} > "$stage3_raw_dir/batch-restart.log" 2>&1
./scripts/check-stage2-read-model.sh > "$stage3_raw_dir/batch-restart-correctness.log" 2>&1

outside_checksum_before="$("${mysql_client[@]}" --batch --skip-column-names --execute "
    SELECT SUM(CRC32(CONCAT_WS('|', game_id, shop_id, played_at, player_nickname,
        course_name, total_score, round_count, game_status)))
    FROM game_history_read_model
    WHERE game_id NOT BETWEEN 400001 AND 410000;
")"
"${mysql_client[@]}" --execute "
    UPDATE game_history_read_model
    SET total_score = total_score + 1
    WHERE game_id BETWEEN 400001 AND 410000;
"
partial_run_id="stage3-backfill-$stage3_result_id"
{
    echo "command=./scripts/run-stage3-batch.sh $partial_run_id backfill 400001 410000"
    /usr/bin/time -p env STAGE3_SKIP_BUILD=true \
        ./scripts/run-stage3-batch.sh "$partial_run_id" backfill 400001 410000
} > "$stage3_raw_dir/partial-backfill.log" 2>&1
outside_checksum_after="$("${mysql_client[@]}" --batch --skip-column-names --execute "
    SELECT SUM(CRC32(CONCAT_WS('|', game_id, shop_id, played_at, player_nickname,
        course_name, total_score, round_count, game_status)))
    FROM game_history_read_model
    WHERE game_id NOT BETWEEN 400001 AND 410000;
")"
./scripts/check-stage2-read-model.sh > "$stage3_raw_dir/partial-backfill-correctness.log" 2>&1
{
    echo "outside_checksum_before=$outside_checksum_before"
    echo "outside_checksum_after=$outside_checksum_after"
} >> "$stage3_raw_dir/partial-backfill.log"

if [[ "$outside_checksum_before" != "$outside_checksum_after" ]]; then
    echo "Rows outside the partial backfill range changed." >&2
    exit 1
fi

"${mysql_client[@]}" --batch --raw --execute "
    SELECT
        p.PARAMETER_VALUE AS run_id,
        ji.JOB_INSTANCE_ID,
        je.JOB_EXECUTION_ID,
        je.STATUS AS job_status,
        je.START_TIME,
        je.END_TIME,
        TIMESTAMPDIFF(MICROSECOND, je.START_TIME, je.END_TIME) / 1000000 AS job_seconds,
        se.STEP_EXECUTION_ID,
        se.STATUS AS step_status,
        se.READ_COUNT,
        se.WRITE_COUNT,
        se.COMMIT_COUNT,
        se.ROLLBACK_COUNT,
        ctx.SHORT_CONTEXT
    FROM BATCH_JOB_INSTANCE ji
    JOIN BATCH_JOB_EXECUTION je ON je.JOB_INSTANCE_ID = ji.JOB_INSTANCE_ID
    JOIN BATCH_JOB_EXECUTION_PARAMS p
      ON p.JOB_EXECUTION_ID = je.JOB_EXECUTION_ID
     AND p.PARAMETER_NAME = 'runId'
    LEFT JOIN BATCH_STEP_EXECUTION se ON se.JOB_EXECUTION_ID = je.JOB_EXECUTION_ID
    LEFT JOIN BATCH_STEP_EXECUTION_CONTEXT ctx ON ctx.STEP_EXECUTION_ID = se.STEP_EXECUTION_ID
    WHERE p.PARAMETER_VALUE IN ('$batch_full_run_id', '$batch_restart_run_id', '$partial_run_id')
    ORDER BY je.JOB_EXECUTION_ID;
" > "$stage3_raw_dir/batch-executions.tsv"

{
    echo -e "method\tresult\tread_model_rows\tcorrectness"
    echo -e "simple_intentional_failure\texit_$simple_failure_exit\t$simple_failure_rows\tnot_complete"
    echo -e "batch_intentional_failure\texit_$batch_failure_exit\t$batch_failure_rows\tcommitted_prefix"
    echo -e "batch_restart\tcompleted\t1000000\tall_rows_match"
    echo -e "batch_partial_backfill\tcompleted\t1000000\tall_rows_match_outside_unchanged"
} > "$stage3_summary_dir/correctness.tsv"

{
    echo "completed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "${mysql_client[@]}" --batch --raw --execute "$source_counts_sql"
} >> "$stage3_result_dir/metadata.txt"

echo "Stage 3 experiment completed: $stage3_result_dir"
