# Stage 4 — Incremental Freshness Experiment

## Problem

Stage 3 made full load, restart, and bounded backfill observable and recoverable, but a completed Read Model immediately becomes stale when `games`, `rounds`, or `round_scores` changes. Rebuilding all one million projections every few minutes would repeat work that is unrelated to the changes. This experiment asks how far a periodic incremental Batch path can satisfy minute-level freshness before continuous change propagation is justified.

## Hypothesis

A stable tuple cursor over Source `updated_at` values, a small replay overlap, and idempotent per-game UPSERT should propagate sparse inserts and updates without a full rebuild. Shorter polling cadences should reduce scheduled freshness lag, but should increase empty runs, replayed rows, connections, and Batch metadata work.

## Cursor design

`games`, `rounds`, and `round_scores` each have `updated_at DATETIME(6)`. The reader unions the three indexed change ranges, maps child changes back to `game_id`, groups duplicates, and orders the affected games by:

```text
(MAX(changed_at), game_id) ASC
```

The lower and upper bounds are tuples. This prevents rows sharing one microsecond timestamp from being skipped: an exact-boundary experiment started after `(2026-08-12 00:21:01, 1000004)` and read games 1000005 and 1000006, both at that timestamp. The normal command reopens the lower bound by five minutes and resets the lower game ID to zero. This intentionally replays recent changes.

The upper timestamp is fixed before a JobInstance starts. `JdbcPagingItemReader` persists its two sort keys at committed chunk boundaries. Projection writes and that paging checkpoint commit in the same chunk transaction. Only after the processing step completes does a second step advance the durable `incremental_read_model_checkpoint` to the fixed upper tuple. A failed job therefore leaves the durable next-run cursor unchanged.

The five-minute overlap is a bounded mitigation for a transaction whose `updated_at` is assigned before it becomes visible. It is not absolute commit-order safety: a transaction open longer than the overlap can commit behind the cursor and be missed. The current Source tables do not expose a database commit sequence, so strict no-gap continuous capture remains unresolved.

## Idempotency

Each affected `game_id` causes a fresh Source JOIN/Aggregate for that game. The writer replaces all eight projection values with `INSERT ... SELECT ... ON DUPLICATE KEY UPDATE`; it does not apply score deltas. Re-reading a change therefore converges to the latest Source state instead of double-counting it.

The retained replay experiment processed one already-applied game. The compact projection checksum was `15319432641` both before and after. The checksum is supporting evidence; the exhaustive Source/projection check is the correctness authority.

Hard deletion remains unsupported. The Source model defines neither a delete event nor soft-delete semantics, and an update-time poll cannot discover a row after physical deletion. No artificial deletion contract was added.

## Workload

Run `20260812T124000Z` used the existing deterministic seed `20260810` dataset:

- 100 shops;
- 1,000,000 games;
- 3,600,000 rounds;
- 6,900,000 round scores;
- 1,000,000 Read Model rows.

An isolated eight-game workload was reset for every cadence. Over one controlled logical hour it performed:

- second 1: insert a new game, round, and score;
- second 421: change an existing game status;
- second 721: change a score and therefore `totalScore`;
- second 1261: change three game statuses at the same timestamp;
- second 2161: change another score;
- second 2941: cancel another game.

The experiment removed those IDs afterward and confirmed the original one-million-row counts. Every cadence ended with all eight workload projections matching Source. The final exhaustive checker confirmed all one million projection rows and the three representative API pages.

## Freshness definition

Source timestamps are controlled application-observed write-completion timestamps, not MySQL internal commit timestamps. Real clock waits were not used. For each event:

```text
Freshness lag = next logical scheduled tick - event time + actual Batch JobExecution duration
```

This conservatively observes visibility at job completion; individual committed chunks may become visible earlier. Application JVM startup time is excluded from `duration_ms`, while the DB status deltas below cover the complete command invocation and surrounding probes.

The same six event times, one-hour window, chunk size 100, five-minute overlap, database, jar, and host were used for all four cadences. Commands are reproducible through:

```bash
./scripts/run-stage4-experiment.sh <unique-result-id>
./scripts/run-stage4-incremental.sh <safe-run-id> [upper-updated-at] [fail-after-count]
```

For a deterministic restart, reuse both the failed run ID and its explicit upper timestamp while setting `fail-after-count` to zero. An omitted upper timestamp deliberately starts a new window from the database clock and is not the same JobInstance.

## Cadence comparison

These are measured values from `benchmarks/stage4/results/20260812T124000Z`:

| Cadence | Runs/hour | Measured event lag range | Changes read (replay included) | Sum of job duration | Empty runs |
| --- | ---: | ---: | ---: | ---: | ---: |
| 60 min | 1 | 659.252–3,599.252 s | 8 | 0.252 s | 0/1 (0%) |
| 10 min | 6 | 61.333–599.351 s | 17 | 4.089 s | 0/6 (0%) |
| 5 min | 12 | 59.535–299.323 s | 29 | 6.449 s | 2/12 (16.7%) |
| 1 min | 60 | 59.254–59.395 s | 90 | 19.601 s | 25/60 (41.7%) |

Each profile's first run reselects the same seven baseline workload games because their initialization timestamp is equal to the durable cursor timestamp and the normal five-minute overlap reopens that range. Accordingly, `Changes read` includes that common seven-row initialization replay as well as in-window changes and later overlap replay; it is not a distinct business-change count.

The controlled event coordinates intentionally occur one second after a minute boundary, so the one-minute samples wait about 59 seconds. The experiment does not claim these six samples are a latency distribution or a worst-case proof for arbitrary arrival times. A change immediately after a tick can approach the cadence plus processing time.

## Failure/boundary experiments

Eight projections were deliberately corrupted, then the incremental job used chunk size two and failed deterministically while reading the sixth affected game:

- failed step: read 6, write 4, commit 2, rollback 1;
- four projections remained mismatched, exactly the uncommitted/remainder set;
- durable cursor remained at `2026-08-12 00:00:00, gameId=0`;
- restart created another JobExecution for the same JobInstance;
- restart read/wrote the remaining four items in three commits;
- final workload mismatch count was zero;
- durable cursor advanced only after completion to the fixed upper tuple.

The five-minute replay behavior and exact tuple-boundary behavior were tested separately. Automated Testcontainers tests repeat new/status/score correctness, equal-timestamp ordering, replay, deterministic failure, same-instance restart, and full fixture equality.

## Source cost

`Innodb_rows_read` and `Questions` are global status deltas around each complete command. They include Batch metadata and framework/database interaction, so they are not presented as pure Source-query counts or CPU measurements.

| Cadence | `Innodb_rows_read` delta/hour | `Questions` delta/hour | Relative observation |
| --- | ---: | ---: | --- |
| 60 min | 113 | 273 | one run, all eight unique games |
| 10 min | 416 | 1,660 | six invocations and overlap replay |
| 5 min | 806 | 3,330 | 12 invocations; 29 reads for 8 unique games |
| 1 min | 3,659 | 16,537 | 60 invocations; 90 reads; 25 empty runs |

No reliable CPU attribution was available on the shared laptop, so no CPU percentage is claimed. The relative DB counters show that shorter cadence increases fixed job/metadata cost and overlap replay even for this sparse workload.

## Operational observations

- Polling all three Source tables is necessary; `games.updated_at` alone cannot see score or round changes.
- The child indexes and union are additional write/storage/query structure needed only to find affected games.
- Five-minute overlap trades bounded race mitigation for repeated work. With a one-minute cadence, the same change can be selected in several consecutive runs.
- Each command opens an application process and creates Batch metadata even when no Source change exists.
- A scheduler was not added. Real scheduling would still require overlap prevention, missed-trigger policy, and monitoring.
- Batch restart recovers chunk work, but it does not solve atomic whole-model publication, deletion propagation, or Source snapshot consistency.

## Decision

Periodic incremental Batch is viable for a five-to-ten-minute freshness target under this sparse controlled workload: it updated only affected games, preserved correctness, and completed each measured job in far less than the cadence. It is not rejected merely because it polls.

A strict one-minute end-to-end target is not comfortably guaranteed. The measured samples were about 59.3 seconds, and an arbitrary arrival can approach 60 seconds plus processing/startup. The one-minute profile also produced 25 empty runs (41.7%), 90 selected rows for only eight unique affected games, and roughly five times the DB-question count of the five-minute profile.

## CDC entry condition

Evidence now satisfies a conditional CDC entry criterion if the product requires strict sub-minute or reliably bounded one-minute propagation: cadence cannot be reduced further without increasing polling, empty-run, metadata, and overlap cost, and updated-time polling still has a long-transaction commit-order gap. This is evidence to evaluate CDC, not evidence that Kafka is mandatory.

If the actual requirement is five or ten minutes and this change rate is representative, incremental Batch is sufficient for now. The requirement must be selected before choosing the next technology.

## Next Question

The next decision should compare the accepted freshness SLO against two remaining facts: periodic polling's fixed/empty-run cost and its lack of a true commit-order cursor. Only a strict continuous/sub-minute requirement justifies proceeding to a CDC experiment. Atomic Read Model publication remains a separate problem and must not be mixed into that comparison.

## Provenance

Tracked evidence under `benchmarks/stage4/results/20260812T124000Z` contains:

- `metadata.txt`: UTC timestamps, commit SHA, dirty state, diff and jar hashes, hardware/software, seed, and clean before/after counts;
- `source-manifest.sha256`: hashes of build, source, test, SQL, and runner files;
- `raw/`: per-cadence command logs/correctness, failure/restart/boundary/replay output, Batch metadata, and final exhaustive correctness;
- `summarized/`: per-run cadence counters, event freshness calculations, and hourly totals.

The executable jar and Docker/MySQL data remain reproducible and are not stored. Compact summaries plus the application/SQL output needed to audit each measured invocation are retained.
