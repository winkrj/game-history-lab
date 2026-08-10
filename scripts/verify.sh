#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$project_root/.gradle}"

docker compose config --quiet
./gradlew clean check
