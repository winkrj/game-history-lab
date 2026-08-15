# Project Working Guide

## Source of truth

- `PROJECT_DESIGN.md` defines the experiment's stages, scope, and final intent.
- `PROJECT_CONTEXT.md` records decisions and the current phase.
- Executable code and tests are authoritative when documentation and behavior disagree; resolve the mismatch in the same change.

## Commands

- Full verification: `./scripts/verify.sh`
- Start local MySQL: `docker compose up -d --wait mysql`
- Run the application: `./gradlew bootRun`
- Generate the default Stage 1 data set: `./scripts/generate-stage1-data.sh --reset`
- Check generated Stage 1 data: `./scripts/check-stage1-data.sh`
- Run a Stage 3 batch range: `./scripts/run-stage3-batch.sh RUN_ID [full|backfill] [MIN_ID] [MAX_ID] [FAIL_ID]`
- Check Stage 3 metadata and correctness: `./scripts/check-stage3-batch.sh`
- Prepare local CDC services: `./scripts/prepare-stage5-cdc.sh`
- Run the Stage 5 CDC experiment: `./scripts/run-stage5-experiment.sh UNIQUE_RESULT_ID`
- Stop local MySQL: `docker compose down`

## Current architecture and scope

- Keep one Spring Boot application until an observed problem requires another deployable component.
- Stage 3 retains the Stage 2 plain-SQL baseline and adds one JDBC-backed Spring Batch job for bulk/restart/backfill experiments.
- The Batch path uses a `game_id` range, 1,000-row chunks, durable execution metadata, and idempotent range UPSERTs.
- Stage 5 uses Debezium and Kafka only for continuous insert/update propagation. Batch remains the initial-load, rebuild, backfill, and bulk-recovery path.
- The representative API defaults to the Read Model; `queryMode=original` remains an explicit experiment comparison path.
- Preserve the representative game-history API and result meaning from `PROJECT_DESIGN.md` across later stages.
- Keep Kotlin approachable to Java/Spring developers: prefer explicit types and ordinary classes and functions over advanced language features.
- Add only what the current stage needs. Record measurements before claiming a performance improvement.

## Outside the current scope

- Transactional Outbox, custom business events, Schema Registry, Kafka Streams, multi-broker topology, complex retry/DLQ infrastructure, Redis, JPA, WebFlux, coroutines, Prometheus, or Grafana.
- Versioned/shadow Read Models, atomic swap, Snapshot + Catch-up, scheduler infrastructure, or speculative abstractions.
- UI, authentication, administration features, or additional search APIs.

## Completion conditions

- Changes stay within the active stage and update `PROJECT_CONTEXT.md` when decisions or phase status change.
- `./scripts/verify.sh` passes, or the exact failure and unverified area are reported.
- Database behavior is covered with MySQL through Testcontainers rather than an in-memory substitute.
