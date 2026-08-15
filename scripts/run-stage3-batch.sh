#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if [[ $# -lt 1 || $# -gt 5 ]]; then
    echo "Usage: $0 RUN_ID [full|backfill] [MIN_GAME_ID] [MAX_GAME_ID] [FAIL_AFTER_GAME_ID]" >&2
    exit 2
fi

stage3_run_id="$1"
stage3_mode="${2:-full}"
stage3_min_game_id="${3:-1}"
stage3_max_game_id="${4:-1000000}"
stage3_fail_after_game_id="${5:-0}"

if [[ "$stage3_mode" != "full" && "$stage3_mode" != "backfill" ]]; then
    echo "Mode must be full or backfill." >&2
    exit 2
fi

for value in "$stage3_min_game_id" "$stage3_max_game_id" "$stage3_fail_after_game_id"; do
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "Game IDs must be non-negative integers." >&2
        exit 2
    fi
done

if (( stage3_min_game_id < 1 || stage3_max_game_id < stage3_min_game_id )); then
    echo "Expected 1 <= MIN_GAME_ID <= MAX_GAME_ID." >&2
    exit 2
fi

docker compose up -d --wait mysql

if [[ "${STAGE3_SKIP_BUILD:-false}" != "true" ]]; then
    ./gradlew bootJar
fi

exec java -jar build/libs/game-history-lab-0.0.1-SNAPSHOT.jar \
    --spring.main.web-application-type=none \
    --stage3.batch.command.enabled=true \
    --stage3.batch.mode="$stage3_mode" \
    --stage3.batch.run-id="$stage3_run_id" \
    --stage3.batch.min-game-id="$stage3_min_game_id" \
    --stage3.batch.max-game-id="$stage3_max_game_id" \
    --stage3.batch.fail-after-game-id="$stage3_fail_after_game_id"
