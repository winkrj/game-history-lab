#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if command -v caffeinate >/dev/null && [[ "${BENCHMARK_CAFFEINATED:-false}" != "true" ]]; then
    exec caffeinate -i env BENCHMARK_CAFFEINATED=true "$0" "$@"
fi

benchmark_base_url="${BENCHMARK_BASE_URL:-http://localhost:8080}"
benchmark_vus="${BENCHMARK_VUS:-4}"
warmup_iterations_per_vu="${WARMUP_ITERATIONS_PER_VU:-5}"
measured_iterations_per_vu="${MEASURED_ITERATIONS_PER_VU:-50}"
benchmark_db_root_password="${BENCHMARK_DB_ROOT_PASSWORD:-root}"
run_id="${BENCHMARK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
result_dir="${BENCHMARK_RESULT_DIR:-benchmarks/stage2/results/$run_id}"

if [[ -e "$result_dir" ]]; then
    echo "Benchmark result directory already exists: $result_dir" >&2
    exit 1
fi

command -v k6 >/dev/null
command -v curl >/dev/null
command -v jq >/dev/null

mysql_container_id="$(docker compose ps -q mysql)"
if [[ -z "$mysql_container_id" ]]; then
    echo "The Compose mysql service is not running." >&2
    exit 1
fi

mkdir -p "$result_dir/pass-1" "$result_dir/pass-2" "$result_dir/mysql"

mysql_root=(
    docker compose exec -T
    -e "MYSQL_PWD=$benchmark_db_root_password"
    mysql mysql --user=root
)

case_parameters() {
    local case_id="$1"
    case "$case_id" in
        shop1_recent7d_page0)
            printf 'from=2025-12-25T00%%3A00%%3A00Z&to=2026-01-01T00%%3A00%%3A00Z&page=0&size=20'
            ;;
        shop1_recent3mo_page0)
            printf 'from=2025-10-01T00%%3A00%%3A00Z&to=2026-01-01T00%%3A00%%3A00Z&page=0&size=20'
            ;;
        shop1_recent3mo_page100)
            printf 'from=2025-10-01T00%%3A00%%3A00Z&to=2026-01-01T00%%3A00%%3A00Z&page=100&size=20'
            ;;
        *)
            echo "Unknown benchmark case: $case_id" >&2
            return 1
            ;;
    esac
}

case_url() {
    local case_id="$1"
    local query_mode="$2"
    printf '%s/shops/1/games?%s&queryMode=%s' \
        "$benchmark_base_url" "$(case_parameters "$case_id")" "$query_mode"
}

capture_global_status() {
    local output_file="$1"
    "${mysql_root[@]}" --batch --raw --execute "
        SHOW GLOBAL STATUS
        WHERE Variable_name IN (
            'Innodb_rows_read',
            'Innodb_buffer_pool_read_requests',
            'Innodb_buffer_pool_reads',
            'Innodb_data_reads',
            'Innodb_data_read',
            'Handler_read_first',
            'Handler_read_key',
            'Handler_read_last',
            'Handler_read_next',
            'Handler_read_prev',
            'Handler_read_rnd',
            'Handler_read_rnd_next'
        );
    " > "$output_file"
}

record_mysql_stats() {
    local benchmark_pid="$1"
    local output_file="$2"

    echo "timestamp_utc,cpu_percent,memory_usage,block_io" > "$output_file"
    while kill -0 "$benchmark_pid" 2>/dev/null; do
        printf '%s,' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$output_file"
        docker stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}},{{.BlockIO}}' "$mysql_container_id" >> "$output_file"
        sleep 1
    done
}

preflight_case() {
    local case_id="$1"
    local original_response
    local read_model_response

    original_response="$(curl -fsS "$(case_url "$case_id" original)" | jq -cS '.')"
    read_model_response="$(curl -fsS "$(case_url "$case_id" read-model)" | jq -cS '.')"
    if [[ "$original_response" != "$read_model_response" ]]; then
        echo "Original/Read Model HTTP mismatch: $case_id" >&2
        exit 1
    fi
    if [[ "$(printf '%s' "$read_model_response" | jq 'length')" != "20" ]]; then
        echo "Expected 20 response rows: $case_id" >&2
        exit 1
    fi
}

run_case() {
    local pass_id="$1"
    local query_mode="$2"
    local case_id="$3"
    local pass_dir="$result_dir/$pass_id"
    local artifact_id="${query_mode}-${case_id}"

    echo "Preflight: $pass_id $artifact_id"
    preflight_case "$case_id"

    echo "Warm-up: $pass_id $artifact_id"
    k6 run \
        -e "BASE_URL=$benchmark_base_url" \
        -e "QUERY_MODE=$query_mode" \
        -e "BENCHMARK_CASE=$case_id" \
        -e "BENCHMARK_VUS=$benchmark_vus" \
        -e "ITERATIONS_PER_VU=$warmup_iterations_per_vu" \
        benchmarks/stage2/k6/game-history.js \
        > "$pass_dir/$artifact_id-warmup.log" 2>&1

    capture_global_status "$result_dir/mysql/$pass_id-$artifact_id-before.tsv"

    echo "Measure: $pass_id $artifact_id"
    k6 run \
        --summary-export "$pass_dir/$artifact_id-summary.json" \
        -e "BASE_URL=$benchmark_base_url" \
        -e "QUERY_MODE=$query_mode" \
        -e "BENCHMARK_CASE=$case_id" \
        -e "BENCHMARK_VUS=$benchmark_vus" \
        -e "ITERATIONS_PER_VU=$measured_iterations_per_vu" \
        benchmarks/stage2/k6/game-history.js \
        > "$pass_dir/$artifact_id.log" 2>&1 &
    local k6_pid=$!

    record_mysql_stats "$k6_pid" "$result_dir/mysql/$pass_id-$artifact_id-docker-stats.csv" &
    local stats_pid=$!

    if ! wait "$k6_pid"; then
        wait "$stats_pid" || true
        sed -n '1,240p' "$pass_dir/$artifact_id.log" >&2
        exit 1
    fi
    wait "$stats_pid"

    capture_global_status "$result_dir/mysql/$pass_id-$artifact_id-after.tsv"

    jq -e --argjson expected_requests "$((benchmark_vus * measured_iterations_per_vu))" \
        '.metrics.http_reqs.count == $expected_requests and .metrics.http_req_failed.value == 0' \
        "$pass_dir/$artifact_id-summary.json" >/dev/null
}

{
    echo "run_id=$run_id"
    echo "started_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "base_url=$benchmark_base_url"
    echo "vus=$benchmark_vus"
    echo "warmup_iterations_per_vu=$warmup_iterations_per_vu"
    echo "measured_iterations_per_vu=$measured_iterations_per_vu"
    echo "measured_requests_per_path_case=$((benchmark_vus * measured_iterations_per_vu))"
    echo "macos_idle_sleep_prevention=${BENCHMARK_CAFFEINATED:-false}"
    echo "mysql_container_id=$mysql_container_id"
    echo "pass_1_order=original:7d-p0,original:3mo-p0,original:3mo-p100,read-model:7d-p0,read-model:3mo-p0,read-model:3mo-p100"
    echo "pass_2_order=read-model:3mo-p100,read-model:3mo-p0,read-model:7d-p0,original:3mo-p100,original:3mo-p0,original:7d-p0"
    echo "git_commit=$(git rev-parse HEAD)"
    echo "git_status_begin"
    git status --short
    echo "git_status_end"
    k6 version
    java -version 2>&1
    docker version --format 'docker_client={{.Client.Version}} docker_server={{.Server.Version}}'
    docker info --format 'docker_cpus={{.NCPU}} docker_memory_bytes={{.MemTotal}}'
    "${mysql_root[@]}" --batch --skip-column-names --execute "SELECT CONCAT('mysql_version=', VERSION()), CONCAT('buffer_pool_bytes=', @@innodb_buffer_pool_size), CONCAT('performance_schema=', @@performance_schema)"
} > "$result_dir/metadata.txt"

cases=(shop1_recent7d_page0 shop1_recent3mo_page0 shop1_recent3mo_page100)
reverse_cases=(shop1_recent3mo_page100 shop1_recent3mo_page0 shop1_recent7d_page0)

for case_id in "${cases[@]}"; do
    run_case pass-1 original "$case_id"
done
for case_id in "${cases[@]}"; do
    run_case pass-1 read-model "$case_id"
done
for case_id in "${reverse_cases[@]}"; do
    run_case pass-2 read-model "$case_id"
done
for case_id in "${reverse_cases[@]}"; do
    run_case pass-2 original "$case_id"
done

{
    echo -e "pass\tquery_mode\tcase\tp95_ms\taverage_ms\tthroughput_rps\terror_rate\trequests"
    for pass_id in pass-1 pass-2; do
        for query_mode in original read-model; do
            for case_id in "${cases[@]}"; do
                jq -r --arg pass_id "$pass_id" --arg query_mode "$query_mode" --arg case_id "$case_id" '
                    [
                        $pass_id,
                        $query_mode,
                        $case_id,
                        .metrics.http_req_duration["p(95)"],
                        .metrics.http_req_duration.avg,
                        .metrics.http_reqs.rate,
                        .metrics.http_req_failed.value,
                        .metrics.http_reqs.count
                    ] | @tsv
                ' "$result_dir/$pass_id/$query_mode-$case_id-summary.json"
            done
        done
    done
} > "$result_dir/http-summary.tsv"

echo "completed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$result_dir/metadata.txt"
echo "Benchmark results: $result_dir"
