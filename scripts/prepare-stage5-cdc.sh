#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

docker compose up -d --wait mysql kafka connect

docker compose exec -T -e MYSQL_PWD=root mysql mysql --user=root --execute "
    CREATE USER IF NOT EXISTS 'debezium'@'%' IDENTIFIED BY 'debezium';
    GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT, LOCK TABLES
        ON *.* TO 'debezium'@'%';
    FLUSH PRIVILEGES;
"

connector_url="http://localhost:${KAFKA_CONNECT_PORT:-8083}/connectors/game-history-mysql"
command -v jq >/dev/null || {
    echo "jq is required to register the Debezium connector." >&2
    exit 1
}
jq '.config' config/debezium/mysql-game-history-connector.json | curl --fail --silent \
    -X PUT \
    -H 'Content-Type: application/json' \
    --data @- \
    "$connector_url/config" >/dev/null

for _ in $(seq 1 60); do
    status="$(curl --fail --silent "$connector_url/status" 2>/dev/null || true)"
    if printf '%s' "$status" | jq --exit-status '
        .connector.state == "RUNNING"
        and (.tasks | length) > 0
        and all(.tasks[]; .state == "RUNNING")
    ' >/dev/null 2>&1; then
        printf '%s\n' "$status"
        exit 0
    fi
    sleep 1
done

echo "Debezium connector did not reach RUNNING state." >&2
curl --silent "$connector_url/status" >&2 || true
exit 1
