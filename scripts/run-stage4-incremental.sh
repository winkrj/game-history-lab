#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

run_id="${1:-}"
upper_updated_at="${2:-}"
fail_after_count="${3:-0}"

if [[ ! "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Usage: $0 SAFE_RUN_ID [UPPER_UPDATED_AT] [FAIL_AFTER_COUNT]" >&2
    exit 2
fi
if [[ ! "$fail_after_count" =~ ^[0-9]+$ ]]; then
    echo "FAIL_AFTER_COUNT must be a non-negative integer." >&2
    exit 2
fi

./scripts/prepare-stage4-schema.sh >/dev/null

if [[ "${STAGE4_SKIP_BUILD:-false}" != "true" ]]; then
    ./gradlew bootJar >/dev/null
fi

command=(
    java -jar build/libs/game-history-lab-0.0.1-SNAPSHOT.jar
    --spring.main.web-application-type=none
    --stage4.incremental.command.enabled=true
    "--stage4.incremental.run-id=$run_id"
    "--stage4.incremental.overlap-seconds=${STAGE4_OVERLAP_SECONDS:-300}"
    "--stage4.incremental.fail-after-count=$fail_after_count"
)
if [[ -n "$upper_updated_at" ]]; then
    command+=("--stage4.incremental.upper-updated-at=$upper_updated_at")
fi

"${command[@]}"
