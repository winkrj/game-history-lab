#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

result_id="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ ! "$result_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
    echo "Result ID must be 1-64 alphanumeric, underscore, or hyphen characters." >&2
    exit 2
fi

result_dir="benchmarks/stage4/results/$result_id"
raw_dir="$result_dir/raw"
summary_dir="$result_dir/summarized"
if [[ -e "$result_dir" ]]; then
    echo "Result directory already exists: $result_dir" >&2
    exit 2
fi
mkdir -p "$raw_dir" "$summary_dir"

db_user="${STAGE4_DB_USERNAME:-game_history}"
db_password="${STAGE4_DB_PASSWORD:-game_history}"
db_name="${STAGE4_DB_NAME:-game_history_lab}"
mysql_client=(
    docker compose exec -T
    -e "MYSQL_PWD=$db_password"
    mysql mysql
    --user="$db_user"
    --database="$db_name"
    --default-character-set=utf8mb4
)

./scripts/prepare-stage4-schema.sh > "$raw_dir/schema-migration.log" 2>&1
./gradlew bootJar > "$raw_dir/build.log" 2>&1
"${mysql_client[@]}" < scripts/sql/cleanup-stage4-workload.sql

source_counts_sql="
    SELECT
        (SELECT COUNT(*) FROM shops) AS shops,
        (SELECT COUNT(*) FROM games) AS games,
        (SELECT COUNT(*) FROM rounds) AS rounds,
        (SELECT COUNT(*) FROM round_scores) AS round_scores,
        (SELECT COUNT(*) FROM game_history_read_model) AS read_model_rows;
"
hardware_info="$(system_profiler SPHardwareDataType | awk -F: '
    /Chip|Total Number of Cores|Memory/ {
        gsub(/^ +/, "", $2)
        printf "%s=%s;", $1, $2
    }
')"

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
    echo "os=$(sw_vers | tr '\n' ';')"
    echo "hardware=$hardware_info"
    echo "dataset_seed=20260810"
    echo "dataset_before"
    "${mysql_client[@]}" --batch --raw --execute "$source_counts_sql"
    echo "dataset_before_end"
    echo "chunk_size=100"
    echo "overlap_seconds=300"
    echo "logical_window_seconds=3600"
    echo "cadences_seconds=3600,600,300,60"
    echo "command=./scripts/run-stage4-experiment.sh $result_id"
} > "$result_dir/metadata.txt"

find build.gradle.kts settings.gradle.kts src/main src/test scripts \
    -type f -print0 | sort -z | xargs -0 shasum -a 256 > "$result_dir/source-manifest.sha256"

status_value() {
    local name="$1"
    "${mysql_client[@]}" --batch --skip-column-names --execute "SHOW GLOBAL STATUS LIKE '$name'" | awk '{print $2}'
}

run_job() {
    local run_id="$1"
    local upper="$2"
    local fail_after="$3"
    java -jar build/libs/game-history-lab-0.0.1-SNAPSHOT.jar \
        --spring.main.web-application-type=none \
        --stage4.incremental.command.enabled=true \
        "--stage4.incremental.run-id=$run_id" \
        --stage4.incremental.overlap-seconds=300 \
        "--stage4.incremental.upper-updated-at=$upper" \
        "--stage4.incremental.fail-after-count=$fail_after"
}

event_offsets="1 421 721 1261 2161 2941"
echo -e "cadence_seconds\trun_number\ttick_seconds\tread_count\twrite_count\tcommit_count\tduration_ms\trows_read_delta\tquestions_delta\tempty" \
    > "$summary_dir/cadence-runs.tsv"
echo -e "cadence_seconds\tevent_offset_seconds\tscheduled_wait_seconds\tprocessing_ms\tfreshness_lag_ms" \
    > "$summary_dir/freshness.tsv"

for cadence in 3600 600 300 60; do
    "${mysql_client[@]}" < scripts/sql/reset-stage4-workload.sql
    cadence_log="$raw_dir/cadence-${cadence}.log"
    : > "$cadence_log"
    tick="$cadence"
    run_number=1
    previous_tick=0
    while (( tick <= 3600 )); do
        {
            echo "tick_seconds=$tick"
            echo "apply_command=SET @elapsed_seconds=$tick; scripts/sql/apply-stage4-workload.sql"
        } >> "$cadence_log"
        {
            printf 'SET @elapsed_seconds = %s;\n' "$tick"
            sed -n '1,$p' scripts/sql/apply-stage4-workload.sql
        } | "${mysql_client[@]}" >> "$cadence_log" 2>&1

        upper="$("${mysql_client[@]}" --batch --skip-column-names --execute "
            SELECT DATE_FORMAT(TIMESTAMP('2026-08-12 00:00:00') + INTERVAL $tick SECOND,
                               '%Y-%m-%dT%H:%i:%s.%f');
        ")"
        before_rows="$(status_value Innodb_rows_read)"
        before_questions="$(status_value Questions)"
        job_output="$(run_job "stage4-c${cadence}-r${run_number}-${result_id}" "$upper" 0 2>&1)"
        after_rows="$(status_value Innodb_rows_read)"
        after_questions="$(status_value Questions)"
        printf '%s\n' "$job_output" >> "$cadence_log"

        processing_line="$(printf '%s\n' "$job_output" | grep 'STAGE4_STEP name=processIncrementalChangesStep')"
        job_line="$(printf '%s\n' "$job_output" | grep 'STAGE4_JOB')"
        read_count="$(printf '%s\n' "$processing_line" | sed -E 's/.* read=([0-9]+).*/\1/')"
        write_count="$(printf '%s\n' "$processing_line" | sed -E 's/.* write=([0-9]+).*/\1/')"
        commit_count="$(printf '%s\n' "$processing_line" | sed -E 's/.* commit=([0-9]+).*/\1/')"
        duration_ms="$(printf '%s\n' "$job_line" | sed -E 's/.* durationMs=([0-9]+).*/\1/')"
        empty=0
        [[ "$read_count" == "0" ]] && empty=1
        echo -e "$cadence\t$run_number\t$tick\t$read_count\t$write_count\t$commit_count\t$duration_ms\t$((after_rows - before_rows))\t$((after_questions - before_questions))\t$empty" \
            >> "$summary_dir/cadence-runs.tsv"

        for event_offset in $event_offsets; do
            if (( event_offset > previous_tick && event_offset <= tick )); then
                scheduled_wait=$((tick - event_offset))
                freshness_ms=$((scheduled_wait * 1000 + duration_ms))
                echo -e "$cadence\t$event_offset\t$scheduled_wait\t$duration_ms\t$freshness_ms" \
                    >> "$summary_dir/freshness.tsv"
            fi
        done
        previous_tick="$tick"
        tick=$((tick + cadence))
        run_number=$((run_number + 1))
    done

    cadence_correctness="$("${mysql_client[@]}" --batch --raw --execute "
        SELECT
            COUNT(*) AS changed_games,
            SUM(CASE WHEN rm.game_id IS NULL
                OR rm.total_score <> expected.total_score
                OR rm.round_count <> expected.round_count
                OR rm.game_status <> expected.game_status THEN 1 ELSE 0 END) AS mismatches
        FROM (
            SELECT g.id, COALESCE(SUM(rs.score), 0) AS total_score,
                   COUNT(DISTINCT r.id) AS round_count, g.game_status
            FROM games g
            LEFT JOIN rounds r ON r.game_id = g.id
            LEFT JOIN round_scores rs ON rs.round_id = r.id
            WHERE g.id BETWEEN 1000001 AND 1000008
            GROUP BY g.id, g.game_status
        ) expected
        LEFT JOIN game_history_read_model rm ON rm.game_id = expected.id;
    ")"
    printf '%s\n' "$cadence_correctness" > "$raw_dir/cadence-${cadence}-correctness.tsv"
    if [[ "$(printf '%s\n' "$cadence_correctness" | tail -1 | awk '{print $2}')" != "0" ]]; then
        echo "Cadence $cadence left a projection mismatch." >&2
        exit 1
    fi
done

# A tuple boundary starts after game 1000004 at a timestamp shared by games 1000004-1000006.
"${mysql_client[@]}" < scripts/sql/reset-stage4-workload.sql
{
    printf 'SET @elapsed_seconds = 1261;\n'
    sed -n '1,$p' scripts/sql/apply-stage4-workload.sql
} | "${mysql_client[@]}"
"${mysql_client[@]}" --execute "
    UPDATE game_history_read_model SET game_status = 'CANCELLED' WHERE game_id = 1000004;
    UPDATE incremental_read_model_checkpoint
    SET cursor_updated_at = '2026-08-12 00:21:01.000000', cursor_game_id = 1000004
    WHERE checkpoint_name = 'game-history';
"
java -jar build/libs/game-history-lab-0.0.1-SNAPSHOT.jar \
    --spring.main.web-application-type=none \
    --stage4.incremental.command.enabled=true \
    "--stage4.incremental.run-id=stage4-boundary-$result_id" \
    --stage4.incremental.overlap-seconds=0 \
    --stage4.incremental.upper-updated-at=2026-08-12T00:21:01.000000 \
    --stage4.incremental.fail-after-count=0 > "$raw_dir/boundary.log" 2>&1
"${mysql_client[@]}" --batch --raw --execute "
    SELECT game_id, game_status FROM game_history_read_model
    WHERE game_id BETWEEN 1000004 AND 1000006 ORDER BY game_id;
" >> "$raw_dir/boundary.log"
grep -q 'STAGE4_STEP name=processIncrementalChangesStep status=COMPLETED read=2 write=2' "$raw_dir/boundary.log"
if [[ "$(tail -3 "$raw_dir/boundary.log" | awk '$2 == "CANCELLED" {count++} END {print count + 0}')" != "3" ]]; then
    echo "Same-timestamp boundary verification failed." >&2
    exit 1
fi

# Eight changed games, chunk size 100 in production; override to two to expose committed prefix.
"${mysql_client[@]}" < scripts/sql/reset-stage4-workload.sql
{
    printf 'SET @elapsed_seconds = 3600;\n'
    sed -n '1,$p' scripts/sql/apply-stage4-workload.sql
} | "${mysql_client[@]}"
"${mysql_client[@]}" --execute "
    UPDATE game_history_read_model SET total_score = total_score + 1000
    WHERE game_id BETWEEN 1000001 AND 1000008;
"
set +e
java -jar build/libs/game-history-lab-0.0.1-SNAPSHOT.jar \
    --spring.main.web-application-type=none \
    --stage4.incremental.command.enabled=true \
    --stage4.incremental.chunk-size=2 \
    "--stage4.incremental.run-id=stage4-failure-$result_id" \
    --stage4.incremental.overlap-seconds=300 \
    --stage4.incremental.upper-updated-at=2026-08-12T01:00:00.000000 \
    --stage4.incremental.fail-after-count=6 > "$raw_dir/failure.log" 2>&1
failure_exit=$?
set -e
echo "client_exit=$failure_exit" >> "$raw_dir/failure.log"
"${mysql_client[@]}" --batch --raw --execute "
    SELECT COUNT(*) AS still_mismatched_after_failure
    FROM game_history_read_model rm
    JOIN (
        SELECT g.id, COALESCE(SUM(rs.score), 0) AS total_score
        FROM games g
        LEFT JOIN rounds r ON r.game_id = g.id
        LEFT JOIN round_scores rs ON rs.round_id = r.id
        WHERE g.id BETWEEN 1000001 AND 1000008
        GROUP BY g.id
    ) source ON source.id = rm.game_id
    WHERE rm.total_score <> source.total_score;
    SELECT * FROM incremental_read_model_checkpoint;
" >> "$raw_dir/failure.log"
if [[ "$failure_exit" == "0" ]] || ! grep -q '^4$' "$raw_dir/failure.log"; then
    echo "Failure injection unexpectedly completed." >&2
    exit 1
fi

java -jar build/libs/game-history-lab-0.0.1-SNAPSHOT.jar \
    --spring.main.web-application-type=none \
    --stage4.incremental.command.enabled=true \
    --stage4.incremental.chunk-size=2 \
    "--stage4.incremental.run-id=stage4-failure-$result_id" \
    --stage4.incremental.overlap-seconds=300 \
    --stage4.incremental.upper-updated-at=2026-08-12T01:00:00.000000 \
    --stage4.incremental.fail-after-count=0 > "$raw_dir/restart.log" 2>&1
"${mysql_client[@]}" --batch --raw --execute "
    SELECT COUNT(*) AS mismatches_after_restart
    FROM game_history_read_model rm
    JOIN (
        SELECT g.id, COALESCE(SUM(rs.score), 0) AS total_score
        FROM games g
        LEFT JOIN rounds r ON r.game_id = g.id
        LEFT JOIN round_scores rs ON rs.round_id = r.id
        WHERE g.id BETWEEN 1000001 AND 1000008
        GROUP BY g.id
    ) source ON source.id = rm.game_id
    WHERE rm.total_score <> source.total_score;
    SELECT * FROM incremental_read_model_checkpoint;
" >> "$raw_dir/restart.log"
if ! grep -A1 '^mismatches_after_restart$' "$raw_dir/restart.log" | tail -1 | grep -qx '0'; then
    echo "Restart did not converge the changed projections." >&2
    exit 1
fi

checksum_before="$("${mysql_client[@]}" --batch --skip-column-names --execute "
    SELECT SUM(CRC32(CONCAT_WS('|', game_id, total_score, round_count, game_status)))
    FROM game_history_read_model WHERE game_id BETWEEN 1000001 AND 1000008;
")"
"${mysql_client[@]}" --execute "
    UPDATE incremental_read_model_checkpoint
    SET cursor_updated_at = '2026-08-12 00:54:01.000000', cursor_game_id = 0
    WHERE checkpoint_name = 'game-history';
"
run_job "stage4-replay-$result_id" "2026-08-12T01:00:00.000000" 0 > "$raw_dir/replay.log" 2>&1
checksum_after="$("${mysql_client[@]}" --batch --skip-column-names --execute "
    SELECT SUM(CRC32(CONCAT_WS('|', game_id, total_score, round_count, game_status)))
    FROM game_history_read_model WHERE game_id BETWEEN 1000001 AND 1000008;
")"
{
    echo "checksum_before=$checksum_before"
    echo "checksum_after=$checksum_after"
} >> "$raw_dir/replay.log"
[[ "$checksum_before" == "$checksum_after" ]]

"${mysql_client[@]}" --batch --raw --execute "
    SELECT
        p.PARAMETER_VALUE AS run_id, ji.JOB_INSTANCE_ID, je.JOB_EXECUTION_ID,
        je.STATUS AS job_status, se.STEP_NAME, se.STATUS AS step_status,
        se.READ_COUNT, se.WRITE_COUNT, se.COMMIT_COUNT, se.ROLLBACK_COUNT,
        ctx.SHORT_CONTEXT
    FROM BATCH_JOB_INSTANCE ji
    JOIN BATCH_JOB_EXECUTION je ON je.JOB_INSTANCE_ID = ji.JOB_INSTANCE_ID
    JOIN BATCH_JOB_EXECUTION_PARAMS p ON p.JOB_EXECUTION_ID = je.JOB_EXECUTION_ID
        AND p.PARAMETER_NAME = 'runId'
    LEFT JOIN BATCH_STEP_EXECUTION se ON se.JOB_EXECUTION_ID = je.JOB_EXECUTION_ID
    LEFT JOIN BATCH_STEP_EXECUTION_CONTEXT ctx ON ctx.STEP_EXECUTION_ID = se.STEP_EXECUTION_ID
    WHERE p.PARAMETER_VALUE LIKE '%$result_id'
    ORDER BY je.JOB_EXECUTION_ID, se.STEP_EXECUTION_ID;
" > "$raw_dir/batch-executions.tsv"

"${mysql_client[@]}" < scripts/sql/cleanup-stage4-workload.sql
"${mysql_client[@]}" --execute "
    UPDATE incremental_read_model_checkpoint
    SET cursor_updated_at = CURRENT_TIMESTAMP(6), cursor_game_id = 9223372036854775807
    WHERE checkpoint_name = 'game-history';
"
./scripts/check-stage2-read-model.sh > "$raw_dir/full-dataset-correctness.log" 2>&1

echo -e "cadence_seconds\truns\ttotal_changes_read\ttotal_duration_ms\trows_read_delta\tquestions_delta\tempty_runs\tempty_ratio" \
    > "$summary_dir/cadence-summary.tsv"
awk -F '\t' 'NR > 1 {
    runs[$1]++; reads[$1]+=$4; duration[$1]+=$7; rows[$1]+=$8; questions[$1]+=$9; empty[$1]+=$10
} END {
    for (c in runs) printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%.4f\n", c, runs[c], reads[c], duration[c], rows[c], questions[c], empty[c], empty[c]/runs[c]
}' "$summary_dir/cadence-runs.tsv" | sort -t $'\t' -k1,1nr >> "$summary_dir/cadence-summary.tsv"

{
    echo "completed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "dataset_after"
    "${mysql_client[@]}" --batch --raw --execute "$source_counts_sql"
    echo "dataset_after_end"
} >> "$result_dir/metadata.txt"

echo "Stage 4 experiment completed: $result_dir"
