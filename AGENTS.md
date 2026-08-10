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
- Stop local MySQL: `docker compose down`

## Current architecture and scope

- Keep one Spring Boot application until an observed problem requires another deployable component.
- Stage 1 uses Spring MVC and Spring JDBC against normalized MySQL tables.
- Preserve the representative game-history API and result meaning from `PROJECT_DESIGN.md` across later stages.
- Keep Kotlin approachable to Java/Spring developers: prefer explicit types and ordinary classes and functions over advanced language features.
- Add only what the current stage needs. Record measurements before claiming a performance improvement.

## Do not add yet

- Spring Batch, Kafka, Debezium, Redis, JPA, WebFlux, coroutines, Prometheus, or Grafana.
- Read Model tables, CDC infrastructure, future-stage packages, or speculative abstractions.
- UI, authentication, administration features, or additional search APIs.

## Completion conditions

- Changes stay within the active stage and update `PROJECT_CONTEXT.md` when decisions or phase status change.
- `./scripts/verify.sh` passes, or the exact failure and unverified area are reported.
- Database behavior is covered with MySQL through Testcontainers rather than an in-memory substitute.
