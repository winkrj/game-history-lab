#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

group_id="${STAGE5_GROUP_ID:-game-history-read-model-cdc}"
fail_on_game_id="${STAGE5_FAIL_ON_GAME_ID:-0}"
auto_offset_reset="${STAGE5_AUTO_OFFSET_RESET:-latest}"

exec java -jar build/libs/game-history-lab-0.0.1-SNAPSHOT.jar \
    --spring.main.web-application-type=none \
    --stage5.cdc.enabled=true \
    "--spring.kafka.consumer.group-id=$group_id" \
    "--spring.kafka.consumer.auto-offset-reset=$auto_offset_reset" \
    "--stage5.cdc.fail-on-game-id=$fail_on_game_id"
