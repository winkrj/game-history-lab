# Stage 2 — one-row-per-game Read Model

## Problem

Stage 1 showed that the representative Original query performs `Game -> Round -> RoundScore` JOIN/Aggregate work before returning 20 rows. On the one-million-game Source, popular-shop three-month requests read 289,842 rows and had multi-second p95 latency. Page 100 did not reduce the upstream JOIN/Aggregate work.

## Hypothesis

Materializing the eight API fields into one row per game will remove JOIN and aggregate work from the request path. A composite index matching shop, time range, and deterministic order should allow page 0 to stop after 20 rows. Page 100 should still traverse its 2,000-row offset, but without child joins or aggregation.

## Environment

Measured on 2026-08-12:

- Apple M1, 8 logical CPUs, 16 GiB RAM, macOS 15.7.3;
- Docker Desktop engine 27.4.0 with 8 CPUs and 7.654 GiB available;
- MySQL 8.4.11 Compose container with a 128 MiB InnoDB buffer pool;
- Java Corretto 21.0.5 Spring Boot executable jar;
- k6 2.0.0 on the same host under `caffeinate -i`;
- loopback HTTP and local MySQL port 3307;
- unchanged deterministic seed `20260810`: 100 shops, 1,000,000 games, 3,600,000 rounds, and 6,900,000 round scores.

The load generator, application, Docker VM, and database shared one machine. Results are a local comparative experiment, not a production capacity claim.

## Implementation

`game_history_read_model` contains exactly the representative response fields:

| Column | Meaning |
| --- | --- |
| `game_id` | Projection identity and primary key; enforces one row per game |
| `shop_id`, `played_at` | Shop and half-open period filter |
| `player_nickname`, `course_name` | Precomputed response values |
| `total_score`, `round_count` | Precomputed Source aggregates |
| `game_status` | Precomputed response status |

The only secondary index is:

```sql
INDEX idx_game_history_shop_played_at (
    shop_id,
    played_at DESC,
    game_id DESC
)
```

It matches the representative filter and `playedAt DESC, gameId DESC` order. `game_id DESC` is explicit so tied timestamps remain deterministic. A covering index was not added because it would duplicate nearly every projection value. A Source foreign key was not added because it would not keep aggregate values fresh and would couple Source reset to the rebuildable projection.

The builder is plain SQL:

```text
TRUNCATE game_history_read_model
-> one INSERT ... SELECT
-> Source LEFT JOIN + SUM + COUNT(DISTINCT)
-> one row per game
```

It has no job repository, chunks, checkpoint, restart metadata, retry, scheduler, staging-table swap, or later-stage framework. Run it with:

```bash
./scripts/rebuild-stage2-read-model.sh
./scripts/check-stage2-read-model.sh
```

The existing endpoint is unchanged and defaults to Original. The explicit experiment route adds only an optional selector:

```text
GET /shops/{shopId}/games?...&queryMode=original
GET /shops/{shopId}/games?...&queryMode=read-model
```

Both modes share request validation, response mapping, `[from, to)`, deterministic ordering, and limit/offset pagination.

## Correctness — measured facts

The Testcontainers fixture compares the complete eight-field result objects for multiple time boundaries and pages. It covers tied timestamps, inclusion at `from`, exclusion at `to`, page 0, and a later offset. The HTTP integration test verifies the same response contract through `queryMode=read-model`.

On the actual Source, the initial build created exactly 1,000,000 Read Model rows for 1,000,000 games. The full checker independently recomputed all one million Source projections and found:

- missing or mismatched projection rows: 0;
- extra projection rows: 0;
- popular shop rows: 100,000;
- ordered result differences for the three benchmark pages: 0.

Read Model speed was not treated as success until these checks passed.

## Build time and storage — measured facts

| Run | SQL build time | End-to-end command |
| --- | ---: | ---: |
| Initial measured build | 42.2492 s | 126.59 s including exhaustive equality and page checks |
| Visibility observation rebuild | 26.9366 s | SQL only |
| Failure recovery rebuild | 25.3001 s | 88.19 s including exhaustive equality and page checks |

MySQL `information_schema.tables` estimated the projection at approximately 100.3 MB of table data and 39.5 MB of indexes after the build. These are engine estimates, not exact filesystem allocation.

## Benchmark conditions

Stage 1 results were not reused as the direct comparison. Both Original and Read Model paths were remeasured from the same new jar and DB in run `benchmarks/stage2/results/20260812T100300Z`.

- cases: the same popular-shop 7-day page 0, 3-month page 0, and 3-month page 100;
- page size: 20; page 100 offset: 2,000;
- concurrency: 4 virtual users;
- per path/case/pass warm-up: 5 iterations per VU, 20 excluded requests;
- per path/case/pass measurement: 50 iterations per VU, 200 requests;
- two passes: case and path order reversed;
- checks: HTTP 200, response size 20, and Original/Read Model preflight JSON equality;
- total measured requests: 2,400; errors: 0;
- EXPLAIN captured only after HTTP measurement.

Reproduction:

```bash
./gradlew bootJar
java -jar build/libs/game-history-lab-0.0.1-SNAPSHOT.jar

# In another shell:
BENCHMARK_RUN_ID=<unique-UTC-id> ./scripts/run-stage2-benchmark.sh
./scripts/capture-stage2-explain.sh benchmarks/stage2/results/<unique-UTC-id>
```

One application log warning reported a 28-second retrograde clock adjustment. The retained raw run had no Docker-stat timestamp gap above three seconds, every k6 HTTP maximum matched its iteration maximum, and all requests completed. No suspension-like metric inconsistency was found.

## Results — measured facts

Each value is shown as pass 1 / pass 2; each pass contains 200 requests for that path and case.

| Query | Original p95 | Read Model p95 | Original throughput | Read Model throughput | Error |
| --- | ---: | ---: | ---: | ---: | ---: |
| 7 days / page 0 | 681.74 / 1,020.96 ms | 3.77 / 10.46 ms | 6.674 / 5.466 req/s | 1,376.42 / 614.59 req/s | 0% / 0% |
| 3 months / page 0 | 10,861.08 / 6,245.20 ms | 10.49 / 6.96 ms | 0.593 / 0.796 req/s | 636.39 / 914.21 req/s | 0% / 0% |
| 3 months / page 100 | 8,746.66 / 9,700.80 ms | 27.54 / 23.58 ms | 0.589 / 0.641 req/s | 209.06 / 220.81 req/s | 0% / 0% |

Paired p95 improvement ranged from about 97.6–180.9x for seven-day page 0, 897.6–1,035.6x for three-month page 0, and 317.6–411.4x for three-month page 100. These are ratios derived from the pass values, not separately measured metrics.

MySQL global-status deltas were identical across passes:

| Query | Original rows read/request | Read Model rows read/request | Reduction |
| --- | ---: | ---: | ---: |
| 7 days / page 0 | 22,045 | 20 | 1,102.3x |
| 3 months / page 0 | 289,842 | 20 | 14,492.1x |
| 3 months / page 100 | 289,842 | 2,020 | 143.5x |

The Read Model measurements finished in under one second per case, so the one-second Docker-stat sampler produced only one CPU sample per case. That is insufficient for a CPU trend and is intentionally not reported as one.

## Execution plan — measured facts

| Query | Original EXPLAIN ANALYZE | Read Model EXPLAIN ANALYZE | Read Model actual rows |
| --- | ---: | ---: | ---: |
| 7 days / page 0 | 462 ms | 0.984 ms | 20 |
| 3 months / page 0 | 2,340 ms | 0.360 ms | 20 |
| 3 months / page 100 | 1,882 ms | 12.6 ms | 2,020 |

Original still accessed four tables in `shops -> games -> rounds -> round_scores` order. The three-month range expanded 25,205 games to 91,993 Game/Round rows and 177,689 rows after RoundScore, grouped all 25,205 games, and then sorted. Traditional EXPLAIN retained `Using temporary; Using filesort`.

Read Model accessed one table through `idx_game_history_shop_played_at`. It had no request-time JOIN, aggregate, temporary table, or filesort. Page 0 stopped after 20 index-range rows regardless of whether the range held 1,920 or 25,205 games. Page 100 traversed 2,020 rows, so offset cost remained visible, but child-row multiplication was gone.

## Observations and interpretation

Measured facts support the hypothesis: request work scales with returned index entries rather than all Source children in the date range. The additional projection storage and build cost bought a three-order-of-magnitude improvement for the three-month page-0 workload in this local experiment. Page 100 remained slower than page 0 because offset traversal was not removed.

The Original path was slower than its Stage 1 run in some cases. Because Stage 2 changed the executable, schema footprint, measurement date, and cache state, this document compares only the freshly remeasured Original and Read Model results from the same Stage 2 run.

## New problems — observed facts

The simple builder introduced concrete operational problems:

- During a measured rebuild, repeated checks returned zero projection rows from `2026-08-12T10:29:57Z` through `10:30:08Z`; the insert committed at 26.9366 seconds. There is no staging-table swap, so the projection is unavailable between truncate and commit.
- An intentional SQL failure immediately after truncate exited with code 1 and left the projection at zero rows.
- Recovery required another complete one-million-row rebuild; the recovery SQL took 25.3001 seconds and the full rebuild/check command took 88.19 seconds.
- The implementation persists no running/completed/failed state, failure position, or checkpoint. Only process output describes a run.
- The builder accepts no period or game range. A partial backfill or correction cannot be requested; rerun means full truncate and rebuild.
- No Source-change propagation path exists. A Source insert, score correction, status change, or cancellation remains stale until the full rebuild is run again.

The failure and empty-visibility behaviors were directly exercised. State tracking, partial backfill, and freshness limitations follow directly from the implemented command surface; they were not solved or benchmarked here.

The broader project design describes a historical Read Model plus current-day Source API merge. This focused experiment materialized the full Source to isolate Read Model request cost, so historical/current merge complexity and date-boundary behavior were not evaluated and are not claimed as findings.

## Decision

The Read Model's added storage and 25–42 second full-build cost are justified for this workload: correctness matched all one million rows while request-time row reads and p95 dropped materially. The comparison establishes why the projection is valuable, not how it should be operated.

## Next question

There is now evidence for a Stage 3 bulk/rebuild/recovery experiment: can managed execution state, restart behavior, and bounded reprocessing prevent a failure from forcing an opaque full rebuild and make recovery observable? This is a question, not an implementation decision. Spring Batch, CDC, Kafka, and scheduling were not added in Stage 2.
