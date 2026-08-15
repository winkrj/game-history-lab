# Stage 1 — Original JOIN baseline

## Experiment purpose and hypothesis

Purpose: establish a repeatable performance baseline for the representative Game History HTTP API over the normalized Source model before introducing a Read Model.

Hypothesis: as the selected date range grows, joining and aggregating `Game -> Round -> RoundScore` will process substantially more child rows than the 20 rows returned by the API. A later offset page will not avoid that upstream work because grouping and ordering happen before `LIMIT/OFFSET`.

## Measured Source data

These values were read from local MySQL after `./scripts/generate-stage1-data.sh --reset` completed:

| Item | Actual value |
| --- | ---: |
| Shops | 100 |
| Games | 1,000,000 |
| Rounds | 3,600,000 |
| Round scores | 6,900,000 |
| Shop 1 games (popular) | 100,000 |
| Shop 2 games (typical) | 9,091 |
| First `played_at` | `2025-01-01 00:00:16.000000` |
| Last `played_at` | `2025-12-31 23:59:51.000000` |

The deterministic seed was `20260810`. Status and child-row distribution remained 5% `CANCELLED`/zero rounds, 10% `IN_PROGRESS`/two rounds/one score, and 85% `COMPLETED`/four rounds/two scores per round. The load took 134.05 seconds of wall-clock time. `./scripts/check-stage1-data.sh` passed afterward, both child orphan counts were zero, and a request to the existing API returned 20 correctly shaped aggregate rows.

## Execution environment

Measured on 2026-08-10 with no other intentional workload:

- host: Apple M1, 8 logical CPUs, 16 GiB RAM, macOS 15.7.3;
- Docker Desktop engine 27.4.0: 8 CPUs and 7.654 GiB memory available;
- application: Java Corretto 21.0.5, Spring Boot executable jar, one local process;
- database: MySQL 8.4.11 Compose container, 128 MiB InnoDB buffer pool, Performance Schema enabled;
- load generator: k6 2.0.0 on the same host, run under macOS `caffeinate -i` to prevent idle system sleep;
- network: loopback HTTP to `localhost:8080`, MySQL in Docker through local port 3307;
- Source schema and indexes were unchanged before, during, and after the experiment.

This is a local comparative baseline, not a production capacity claim. The database working set is much larger than its 128 MiB buffer pool and the load generator, application, Docker VM, and database share one machine.

## Query cases

All cases call `GET /shops/1/games`, use the half-open range `[from, to)`, `size=20`, and order by `playedAt DESC, gameId DESC`.

| Case ID | From | To | Page / offset | Matching games before pagination |
| --- | --- | --- | ---: | ---: |
| `shop1_recent7d_page0` | `2025-12-25T00:00:00Z` | `2026-01-01T00:00:00Z` | 0 / 0 | 1,920 |
| `shop1_recent3mo_page0` | `2025-10-01T00:00:00Z` | `2026-01-01T00:00:00Z` | 0 / 0 | 25,205 |
| `shop1_recent3mo_page100` | `2025-10-01T00:00:00Z` | `2026-01-01T00:00:00Z` | 100 / 2,000 | 25,205 |

Page 100 keeps the result inside a meaningful 25,205-game range while making the database retain 2,020 sorted aggregate rows instead of only 20.

## Benchmark method

For each case, k6 used the `per-vu-iterations` executor:

- concurrency: 4 virtual users;
- warm-up: 5 iterations per VU, 20 requests total, excluded from measurements;
- measurement: 50 iterations per VU, 200 requests total;
- pass 1 order: 7-day page 0, 3-month page 0, 3-month page 100;
- pass 2 order: the reverse order, to expose order/cache effects;
- response checks: HTTP 200 and exactly 20 response rows;
- error rate: k6 `http_req_failed`;
- MySQL global counters and container CPU: captured after warm-up and around each measured case;
- EXPLAIN: captured only after all HTTP measurements, so it did not affect latency samples.

Reproduction commands:

```bash
./scripts/generate-stage1-data.sh --reset
./scripts/check-stage1-data.sh
./gradlew bootJar
java -jar build/libs/game-history-lab-0.0.1-SNAPSHOT.jar

# In another shell:
BENCHMARK_RUN_ID=<unique-UTC-id> ./scripts/run-stage1-benchmark.sh
./scripts/capture-stage1-explain.sh benchmarks/stage1/results/<unique-UTC-id>
```

The recorded raw run is `benchmarks/stage1/results/20260810T122400Z`. `http-summary.tsv` is the compact HTTP result; per-case k6 logs/JSON, MySQL status, periodic Docker statistics, exact SQL, all EXPLAIN formats, and environment metadata remain beside it. Performance Schema digest artifacts were also captured experimentally, but their count deltas were not consistent with the 200 HTTP requests and are excluded from the findings. The reusable runner no longer collects that unreliable metric.

## HTTP results — measured facts

Each row contains 200 measured requests. Values are reported per pass rather than pooled so order/cache variation remains visible.

| Case | Pass | p95 | Throughput | Error rate |
| --- | ---: | ---: | ---: | ---: |
| 7 days / page 0 | 1 | 853.60 ms | 5.946 req/s | 0.00% |
| 7 days / page 0 | 2 | 789.24 ms | 6.029 req/s | 0.00% |
| 3 months / page 0 | 1 | 6,424.08 ms | 0.845 req/s | 0.00% |
| 3 months / page 0 | 2 | 4,685.38 ms | 0.890 req/s | 0.00% |
| 3 months / page 100 | 1 | 6,784.37 ms | 0.770 req/s | 0.00% |
| 3 months / page 100 | 2 | 7,526.99 ms | 0.706 req/s | 0.00% |

All 1,200 measured requests succeeded. The corresponding MySQL container CPU samples averaged 151.53–152.61% for the 7-day case and 183.40–191.96% for the 3-month cases; maxima were 174.93% and 246.67%, respectively. More than one Docker CPU core can make the percentage exceed 100%. Docker-stat timestamps had no gap above three seconds, so no host/process suspension contaminated this run.

MySQL global-status deltas were stable across passes:

| Case | `Innodb_rows_read` per request | Physical buffer-pool reads per request |
| --- | ---: | ---: |
| 7 days / page 0 | 22,045 | 1,843–1,846 |
| 3 months / page 0 | 289,842 | 10,881–10,893 |
| 3 months / page 100 | 289,842 | 10,881–10,882 |

The identical three-month row counts show that offset 2,000 did not reduce upstream data access. A concurrent per-request MySQL server-time series was not recorded reliably in this run; the separately executed EXPLAIN ANALYZE times below are the available database-only timing evidence and are not substituted for HTTP percentiles.

## EXPLAIN ANALYZE — measured facts

The join order for every case was `shops` (`const`) -> `games` (range) -> `rounds` (`ref`) -> `round_scores` (`ref`). Existing indexes were used:

- `games.idx_games_shop_played_at (shop_id, played_at DESC, id DESC)`;
- `rounds.uk_rounds_game_number (game_id, round_number)`;
- `round_scores.idx_round_scores_round_id (round_id)`.

| Observation | 7 days / page 0 | 3 months / page 0 | 3 months / page 100 |
| --- | ---: | ---: | ---: |
| EXPLAIN ANALYZE total time | 482 ms | 2,695 ms | 3,133 ms |
| Games: estimated / actual | 1,920 / 1,920 | 51,784 / 25,205 | 51,784 / 25,205 |
| Rows after Game-Round join | 7,000 | 91,993 | 91,993 |
| Rows after RoundScore join | 13,512 | 177,689 | 177,689 |
| Aggregate output games | 1,920 | 25,205 | 25,205 |
| Final sort retained rows | 20 | 20 | 2,020 |

Traditional EXPLAIN reports `Using temporary; Using filesort`. There is no full games-table scan: the shop/time range uses `idx_games_shop_played_at`. However, MySQL sorts games for group processing, performs tens of thousands of child index lookups, aggregates the complete selected game range, and then performs the final deterministic sort before applying the limit/offset. The optimizer overestimated the three-month games by about 2.05x and the joined rows by about 3.89x (690,911 estimated versus 177,689 actual).

## Interpretation

The hypothesis is supported. Expanding from 1,920 to 25,205 games increased stable database rows read from about 22 thousand to about 290 thousand per request and reduced HTTP throughput from roughly 6 requests/second to roughly 1 request/second or less. The main cost is not a full `games` scan; it is range materialization followed by repeated Round/RoundScore lookups, group aggregation, temporary work, and sorting over all matching games even though only 20 rows are returned.

The later offset was slower in both passes, but the added p95 cost ranged from about 5.6% to 60.7%. Rows read remained identical while the final sort retained 2,020 rows instead of 20. This supports an offset/sort contribution, but the wide relative range also shows that cache and shared-local-machine variation remain material. The experiment does not isolate those effects into separate causal percentages.

## Unexpected observations and deferred optimization

Expected date-range growth was clear, but the size of the later-page penalty varied more than expected. The two passes are retained to make that limitation visible. A production capacity number would require isolated hardware, longer steady-state runs, and disk/cache control; this laboratory baseline is still sufficient for an Original JOIN versus Read Model comparison on the same machine.

No index was added, removed, or changed. No query hint, query rewrite, cache, Read Model, Spring Batch, Kafka, Debezium, or monitoring stack was introduced. In particular, the existing Source indexes were observed rather than tuned after the result.

## Decision

The current one-million-game scale already produces multi-second p95 latency, about 290 thousand database rows read per three-month request, high MySQL CPU, temporary/filesort work, and 177,689 joined rows before returning 20. Increasing data volume is unnecessary to demonstrate the Stage 1 bottleneck.

Stage 1 can therefore close. The next experiment should proceed to Stage 2 by defining the one-row-per-game Read Model and initially populating historical rows with plain SQL or a simple application job. This document and its raw run remain the unchanged Original JOIN comparison baseline; index/query tuning is still deferred.
