# Stage 5 — CDC + Kafka Experiment

## Problem

Stage 4 showed that periodic incremental Batch is adequate for a five-to-ten-minute freshness target, but a strict seconds-level target changes the trade-off. Its controlled one-minute profile waited about 59 seconds, executed 60 jobs in one logical hour, produced 25 empty runs (41.7%), and increased global MySQL `Questions` to 16,537. The question here is whether binlog CDC can remove periodic Source polling and propagate changes within seconds without changing projection meaning.

## Evidence from Stage 4

The CDC decision starts from measured polling behavior, not from a preference for Kafka. Stage 4 safely handled tuple boundaries, replay, and restart with `(updated_at, game_id)`, a five-minute overlap, and idempotent UPSERT. It remained suitable at five-to-ten minutes. Its limiting evidence was fixed polling work and an almost full-cadence wait at one minute, plus a bounded long-transaction race that `updated_at` overlap cannot eliminate absolutely.

## Freshness Requirement

For this experiment the accepted requirement is normal-condition propagation within a few seconds. The primary measurement is:

```text
Freshness lag = client-observed completion of the Source SQL transaction
              → expected value first observed in game_history_read_model
```

The script takes its start timestamp immediately after the MySQL client returns, then polls the projection. This is not a MySQL internal commit timestamp: client/process and probe overhead remain in the measurement. Debezium `source.ts_ms` and consumer receive/commit timestamps are retained in application logs only as secondary transport evidence.

## Hypothesis

MySQL row-binlog capture should eliminate scheduled empty polling and reduce normal propagation to well under one minute. Each CDC record should only identify an affected `gameId`; re-reading the latest normalized Source and UPSERTing the full projection should preserve Stage 2–4 meaning and make at-least-once replay safe. The expected trade-off is three continuously operating components and offset/connector lifecycle work.

## Architecture

```text
MySQL 8.4 ROW/FULL binlog
  → Debezium Connect 3.4.3.Final
  → Kafka 4.1.1 table topics
  → Spring Kafka consumer
  → affected gameId
  → latest Source LEFT JOIN/Aggregate
  → game_history_read_model UPSERT
```

There is one MySQL, one Kafka broker, one Connect worker/task, and one application consumer. Source and Read Model remain in the same experimental MySQL, so global DB counters cannot attribute cost to them independently.

The measured host was an Apple M1 laptop with eight cores and 16 GB memory, macOS 15.7.3, Docker 27.4.0, Java 21.0.5, Spring Boot 4.1.0, and MySQL 8.4.11. Other local containers were present; the one-shot resource samples are therefore context, not isolated capacity results.

## CDC Configuration

Compose enables a pinned MySQL server ID, row binlog, and full row images. `prepare-stage5-cdc.sh` explicitly creates the Debezium user and replication grants on every setup; it does not rely on first-volume initialization. The connector captures only `games`, `rounds`, and `round_scores`, excludes schema-change records, and uses `snapshot.mode=no_data`.

`no_data` is deliberate: Spring Batch owns the one-million-row initial load and CDC starts from the connector position. It does not solve the handoff between a completed Batch load and connector start. A change committed in an incorrectly coordinated handoff can be missed; Snapshot + Catch-up was not implemented.

## Kafka Configuration

The local topology uses `apache/kafka:4.1.1` in single-node KRaft mode. The three captured table topics each have one partition and replication factor one. A single connector task and one partition per table are enough for this correctness/freshness experiment; no Schema Registry, Streams, UI, or multi-broker topology was added.

The initial local Connect startup created its compacted offset/status topics with image defaults before the one-partition environment values were added. The retained run therefore contains 25 offset partitions and five status partitions even though clean future Compose creation requests one each. This does not change the three one-partition CDC data topics, but is recorded rather than hidden. Kafka data is not volume-backed: container recreation loses broker records and Connect/consumer offsets. That is acceptable only for this resettable local lab and is an operational limitation.

## Consumer Design

The consumer uses three table topics and Spring Kafka `AckMode.RECORD`. Its listener is a JDBC transaction:

1. parse the Debezium record;
2. resolve one affected game ID;
3. execute the shared latest-Source projection UPSERT;
4. return after the DB transaction commits;
5. let the container commit the Kafka record offset.

An exception rolls back the DB transaction. `CommonContainerStoppingErrorHandler` stops the consumer instead of adding a retry/DLQ policy; restarting the application with the same group causes redelivery. DB commit and Kafka offset commit are not atomic. A crash after DB commit but before offset commit can replay the record, which is safe because the projection update is idempotent. This is at-least-once convergence, not Kafka exactly-once processing.

## Projection Strategy

CDC payloads are not mapped into projection fields. `GameHistoryProjectionUpdater`, also used by the Stage 4 incremental writer, runs the canonical Source `LEFT JOIN`/`SUM`/`COUNT(DISTINCT)` calculation and whole-row `ON DUPLICATE KEY UPDATE`.

Affected IDs are resolved as follows:

- `games`: `id` in the captured row;
- `rounds`: `game_id` in the captured row;
- `round_scores`: captured `round_id`, followed by `SELECT game_id FROM rounds`.

This experiment covers inserts and updates. Re-parenting can require both before/after game IDs, and a physical child delete can arrive after its parent is unavailable. The Source has no agreed delete/soft-delete contract, so re-parent/delete propagation was not added or claimed.

The representative HTTP API now defaults to the Read Model. `queryMode=original` remains only as an explicit experiment comparison path; request, response, range, ordering, and pagination contracts are unchanged.

## Correctness Workload

Run `20260813T124200Z` began with seed `20260810`: 100 shops, 1,000,000 games, 3,600,000 rounds, 6,900,000 scores, and 1,000,000 projection rows. It then sent real MySQL transactions through Debezium and Kafka:

| Scenario | Expected projection | Measured visibility lag |
| --- | --- | ---: |
| new game + round + score | `totalScore=10` | 356 ms |
| game status update | `COMPLETED` | 272 ms |
| second round insert | `roundCount=2` | 423 ms |
| score insert/update | `totalScore=35` | 260 ms |
| same-game rapid final update | `totalScore=40` | 425 ms |

The main consumer committed 30 actual CDC records: 24 `games`, two `rounds`, and four `round_scores`. The final exhaustive Source/projection checker found exactly 1,000,002 Source games and projection rows with all eight values equal, no missing/extra rows, and all representative pages equal. The two additional games are the retained correctness and failure workloads.

## Freshness Results

Twenty sequential status changes used the same consumer, MySQL, host, projection query, and polling method. A later change was not issued until the preceding expected projection value was visible, so samples cannot be satisfied by a subsequent state.

| Samples | p50 | p95 | max | missing/error |
| ---: | ---: | ---: | ---: | ---: |
| 20 | 395 ms | 450 ms | 468 ms | 0 |

Observed range was 258–468 ms. These are local normal-condition measurements, not an SLO proof under broker failure, backlog, rebalance, or production load. They are directly comparable to Stage 4 only at the definition boundary (write completion to projection visibility); Stage 4 used controlled logical scheduler ticks rather than real asynchronous transport.

## Polling vs CDC Cost

| Observation | 1-minute Incremental Batch | Stage 5 CDC |
| --- | ---: | ---: |
| scheduled executions | 60/hour | none |
| empty runs | 25/60 (41.7%) | not applicable; no polling job |
| global MySQL Questions | 16,537/logical hour | 6 during measured 10-second idle window; 490 across 5 scenarios + 20 samples and probes |
| change work | overlap can replay tuples | one latest-Source projection per delivered record; score events add parent lookup |

The absolute `Questions` values are not normalized equivalent-duration load tests. Stage 5's change delta includes workload SQL, observer polling, status probes, projection queries/writes, and shared-MySQL activity. The defensible conclusion is narrower: CDC ran no periodic change-discovery SELECT/job while idle; it did not reduce Source cost to zero. MySQL still writes/retains binlog, Connect maintains a replication connection, and every delivered event causes a current-Source re-read.

One-shot Docker samples were retained only as environmental observations. Before/after samples showed Connect around 848–864 MiB and Kafka around 388–400 MiB on the shared 16 GB laptop. These are not stable CPU or capacity measurements and are not used to claim efficiency.

## Duplicate / Replay Experiment

The first replay attempt accidentally inherited `auto-offset-reset=latest` and consumed zero records. It is retained in raw evidence but excluded. A corrected fresh group explicitly used `earliest`, applied 31 retained CDC records, reached zero lag, and produced the same two-workload-row checksum before and after: `3287816278`. The final exhaustive Source equality had already passed. The runner now requires at least one applied replay record as well as zero group lag.

This validates idempotent latest-state replay; it does not claim exactly-once delivery.

## Consumer Failure / Restart

The deterministic failure consumer joined at game-topic offset 24, then received a newly inserted game at offset 24 and threw after executing the projection UPSERT but before listener success. The JDBC transaction rolled back; the script asserted zero projection rows for that game. After failure the group remained at offset 24 while log end was 25 (`LAG=1`).

The process had to be restarted manually because the minimal error handler stops the container. Restarting the same group with failure disabled re-read offset 24, created the correct projection, and advanced the group to offset 25 with zero lag. No record was lost. Human/process-manager intervention is therefore still required; retry and poison-message operation remain unresolved.

A second retained failure probe made the rollback state explicit: after a Source status changed to `IN_PROGRESS`, deterministic processing failure left the projection at its previous `COMPLETED` value and the group at game offset 25 with log end 26 (`LAG=1`). Same-group restart changed the projection to `IN_PROGRESS`, advanced to offset 26, and the exhaustive checker again passed all 1,000,002 rows.

## Ordering Observation

The table topics do not provide global cross-topic ordering. In one transaction the same game changed status twice and its score changed; consumers may observe redundant triggers or skip an intermediate projection state because every trigger reads the latest committed Source. The final projection converged to the latest `totalScore=40`, which is useful for this current-state Read Model. It would not preserve an audit history or intermediate business event semantics.

## Operational Complexity

Compared with incremental Batch, the CDC path adds a binlog configuration/retention responsibility, a replication user, Kafka broker, Connect worker, connector configuration and offsets, consumer group offsets/rebalances, three table schemas/topics, and manual restart behavior. Local startup order matters: connector status must be `RUNNING` before the workload begins. Broker/Connect state is ephemeral in the current Compose lab.

The current direct row CDC path also couples the resolver to Source table identifiers and row keys, although it deliberately avoids coupling projection values to event payload. Delete/re-parent handling, DLQ/retry policy, poison records, monitoring, and Batch-to-CDC handoff remain explicit gaps.

## Batch vs CDC Responsibility

- Spring Batch remains responsible for initial load, full rebuild, bounded backfill, and bulk recovery with durable job/checkpoint metadata.
- CDC + Kafka is responsible only for continuous post-handoff insert/update propagation.

The two paths share projection meaning and are complementary. CDC does not replace Batch for one-million-row recovery; Batch does not need one-minute polling when the seconds-level requirement is active.

## Remaining Problems

- Batch completion to `snapshot.mode=no_data` connector-start handoff has no Snapshot + Catch-up protocol.
- DB projection commit and Kafka offset commit are two systems; replay is possible.
- Consumer failure stops processing until restart; there is no retry/DLQ/poison-message policy.
- Physical delete and game re-parent propagation are undefined.
- Kafka/Connect state is ephemeral locally and there is no monitoring or multi-broker resilience.
- Atomic rebuild publication, partial initial visibility, and Source snapshot consistency remain separate Stage 3 problems.

No Outbox, business-event publisher, Schema Registry, Streams, DLQ framework, versioned Read Model, cache, or monitoring stack was implemented.

## Decision

For the newly assumed seconds-level normal-condition requirement, the CDC hypothesis is supported. All 20 samples were below 0.5 seconds locally with no missing changes, the four required Source change types converged, deterministic failure redelivered, and actual earliest replay preserved the projection. It also removes periodic change-discovery polling.

That improvement is not free: Kafka and Connect consume substantial memory and introduce offset, connector, restart, handoff, and schema-operational responsibilities. If the accepted requirement returns to five-to-ten minutes, Stage 4 remains the simpler adequate choice.

## Next Question

Stage 5 answers the current freshness question without requiring another feature immediately. Before productionization, the next evidence-driven question is which observed reliability gap matters first: Batch-to-CDC handoff, automatic poison-record recovery, or delete semantics. No next technology is selected here, and Outbox/Versioned Read Model/Snapshot + Catch-up are not pre-implemented.

## Provenance

Reproduce the topology and run with:

```bash
./scripts/prepare-stage5-cdc.sh
./scripts/run-stage5-experiment.sh <unique-result-id>
```

Tracked evidence under `benchmarks/stage5/results/20260813T124200Z` contains the UTC run time, git SHA and dirty state, diff/jar/source hashes, dataset and IDs, pinned versions, connector status, Compose state, raw consumer/offset logs, per-sample timestamps, cost counters, Docker samples, replay correction metadata, and exhaustive equality output. Regenerable jars, database pages, broker logs, and the Kafka log itself are not tracked.
