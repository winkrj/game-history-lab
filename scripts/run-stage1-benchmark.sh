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
result_dir="${BENCHMARK_RESULT_DIR:-benchmarks/stage1/results/$run_id}"

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

case_url() {
    local case_id="$1"
    case "$case_id" in
        shop1_recent7d_page0)
            printf '%s/shops/1/games?from=2025-12-25T00%%3A00%%3A00Z&to=2026-01-01T00%%3A00%%3A00Z&page=0&size=20' "$benchmark_base_url"
            ;;
        shop1_recent3mo_page0)
            printf '%s/shops/1/games?from=2025-10-01T00%%3A00%%3A00Z&to=2026-01-01T00%%3A00%%3A00Z&page=0&size=20' "$benchmark_base_url"
            ;;
        shop1_recent3mo_page100)
            printf '%s/shops/1/games?from=2025-10-01T00%%3A00%%3A00Z&to=2026-01-01T00%%3A00%%3A00Z&page=100&size=20' "$benchmark_base_url"
            ;;
        *)
            echo "Unknown benchmark case: $case_id" >&2
            return 1
            ;;
    esac
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

run_case() {
    local pass_id="$1"
    local case_id="$2"
    local pass_dir="$result_dir/$pass_id"
    local request_url
    request_url="$(case_url "$case_id")"

    echo "Preflight: $pass_id $case_id"
    curl -fsS "$request_url" | jq -e 'length == 20' >/dev/null

    echo "Warm-up: $pass_id $case_id"
    k6 run \
        -e "BASE_URL=$benchmark_base_url" \
        -e "BENCHMARK_CASE=$case_id" \
        -e "BENCHMARK_VUS=$benchmark_vus" \
        -e "ITERATIONS_PER_VU=$warmup_iterations_per_vu" \
        benchmarks/stage1/k6/game-history.js \
        > "$pass_dir/$case_id-warmup.log" 2>&1

    capture_global_status "$result_dir/mysql/$pass_id-$case_id-before.tsv"

    echo "Measure: $pass_id $case_id"
    k6 run \
        --summary-export "$pass_dir/$case_id-summary.json" \
        -e "BASE_URL=$benchmark_base_url" \
        -e "BENCHMARK_CASE=$case_id" \
        -e "BENCHMARK_VUS=$benchmark_vus" \
        -e "ITERATIONS_PER_VU=$measured_iterations_per_vu" \
        benchmarks/stage1/k6/game-history.js \
        > "$pass_dir/$case_id.log" 2>&1 &
    local k6_pid=$!

    record_mysql_stats "$k6_pid" "$result_dir/mysql/$pass_id-$case_id-docker-stats.csv" &
    local stats_pid=$!

    if ! wait "$k6_pid"; then
        wait "$stats_pid" || true
        sed -n '1,240p' "$pass_dir/$case_id.log" >&2
        exit 1
    fi
    wait "$stats_pid"

    capture_global_status "$result_dir/mysql/$pass_id-$case_id-after.tsv"

    jq -e --argjson expected_requests "$((benchmark_vus * measured_iterations_per_vu))" \
        '.metrics.http_reqs.count == $expected_requests and .metrics.http_req_failed.value == 0' \
        "$pass_dir/$case_id-summary.json" >/dev/null
}

{
    echo "run_id=$run_id"
    echo "started_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "base_url=$benchmark_base_url"
    echo "vus=$benchmark_vus"
    echo "warmup_iterations_per_vu=$warmup_iterations_per_vu"
    echo "measured_iterations_per_vu=$measured_iterations_per_vu"
    echo "measured_requests_per_case=$((benchmark_vus * measured_iterations_per_vu))"
    echo "macos_idle_sleep_prevention=${BENCHMARK_CAFFEINATED:-false}"
    echo "mysql_container_id=$mysql_container_id"
    echo "pass_1_order=shop1_recent7d_page0,shop1_recent3mo_page0,shop1_recent3mo_page100"
    echo "pass_2_order=shop1_recent3mo_page100,shop1_recent3mo_page0,shop1_recent7d_page0"
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

pass_1_cases=(shop1_recent7d_page0 shop1_recent3mo_page0 shop1_recent3mo_page100)
pass_2_cases=(shop1_recent3mo_page100 shop1_recent3mo_page0 shop1_recent7d_page0)

for case_id in "${pass_1_cases[@]}"; do
    run_case "pass-1" "$case_id"
done
for case_id in "${pass_2_cases[@]}"; do
    run_case "pass-2" "$case_id"
done

{
    echo -e "pass\tcase\tp95_ms\taverage_ms\tthroughput_rps\terror_rate\trequests"
    for pass_id in pass-1 pass-2; do
        for case_id in "${pass_1_cases[@]}"; do
            jq -r --arg pass_id "$pass_id" --arg case_id "$case_id" '
                [
                    $pass_id,
                    $case_id,
                    .metrics.http_req_duration["p(95)"],
                    .metrics.http_req_duration.avg,
                    .metrics.http_reqs.rate,
                    .metrics.http_req_failed.value,
                    .metrics.http_reqs.count
                ] | @tsv
            ' "$result_dir/$pass_id/$case_id-summary.json"
        done
    done
} > "$result_dir/http-summary.tsv"

echo "completed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$result_dir/metadata.txt"
echo "Benchmark results: $result_dir"
