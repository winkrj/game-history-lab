# Stage 3 — Batch Recovery Experiment

## Problem

Stage 2 removed request-time JOIN/Aggregate work with a one-row-per-game Read Model, but its builder is one destructive command:

```text
TRUNCATE game_history_read_model
→ INSERT ... SELECT Source JOIN/Aggregate
```

That command has no durable execution status, processed count, failure position, checkpoint, restart boundary, or bounded backfill input. This experiment asks what minimum bulk-processing structure makes those responsibilities explicit.

## Evidence from Stage 2

On the same one-million-game Source, Stage 2 observed SQL rebuilds of 25.3001–42.2492 seconds. A deliberately failed rebuild after `TRUNCATE` exited 1 and left zero rows. Recovery required another complete rebuild. The command surface had no way to select a period or game range, and Source changes remained stale until another rebuild.

Those are directly observed limitations of the retained baseline. They motivated the experiment; they did not preselect a framework result.

## Hypothesis

A JDBC-backed chunk job with a unique `game_id` checkpoint and idempotent range UPSERT should expose execution status and committed counts, resume a failed JobInstance after its last committed chunk, and backfill a bounded range without rewriting all one million projection rows. The expected cost is extra processing structure and metadata, and possibly slower full processing than one set-based SQL statement.

## Simple Baseline

`src/main/resources/stage2-rebuild-read-model.sql` and `scripts/rebuild-stage2-read-model.sh` remain unchanged. Run `20260812T111000Z` measured:

- normal SQL build: 385.5919 seconds;
- wrapper elapsed: 722.67 seconds, including exhaustive Source/projection equality and three representative-page comparisons;
- intentional `KILL QUERY` during the INSERT: client exit 1 and zero Read Model rows after failure;
- recorded recovery capability: none; the baseline procedure is another full rebuild;
- recorded partial-backfill capability: none; an operator would need to author and validate one-off range SQL.

The SQL time was much slower than Stage 2's 25–42 second runs. This experiment records the actual value but does not infer a cause. Different host/cache state means cross-stage build timings are not directly compared. The Simple and Batch measurements here were executed sequentially by one runner, so order and cache effects also prevent treating their timing difference as a controlled performance benchmark.

## Spring Batch Decision

Spring Batch was introduced because its JDBC JobRepository and chunk ExecutionContext directly address the observed status/checkpoint/restart gap. The implementation uses only those capabilities; it adds no scheduler, retry policy, partitioning, admin UI, or additional job architecture.

Spring Boot 4.1's default Batch repository is resourceless, so the project explicitly enables Batch processing and the JDBC JobRepository. The Batch 6.0.4 MySQL metadata schema is retained in `batch-schema.sql` with only idempotent `IF NOT EXISTS` creation added.

## Implementation

There is one job and one step:

```text
gameHistoryReadModelJob
└─ buildReadModelStep (chunk size 1,000)
   ├─ JdbcPagingItemReader: ordered Source game_id pages
   ├─ deterministic failure processor
   └─ ReadModelChunkWriter: one JOIN/Aggregate UPSERT per ID chunk
```

JobInstance-identifying parameters are `runId`, `mode`, `minGameId`, and `maxGameId`. `failAfterGameId` is non-identifying so a failed instance can be restarted with injection disabled. Both full processing and backfill use the same inclusive ID-range operation; full uses 1–1,000,000 and backfill supplies narrower bounds.

The writer computes the same `SUM(round_scores.score)` and `COUNT(DISTINCT rounds.id)` projection as Stage 2 and UPSERTs it. It does not clear the Read Model first. Each successful 1,000-row chunk and its reader checkpoint commit in one transaction.

Commands:

```bash
# One range/job execution
./scripts/run-stage3-batch.sh RUN_ID full 1 1000000
./scripts/run-stage3-batch.sh RUN_ID backfill 400001 410000

# Full retained experiment, including destructive failure tests
./scripts/run-stage3-experiment.sh <unique-UTC-result-id>

# Inspect JDBC metadata and exhaustive projection correctness
./scripts/check-stage3-batch.sh
```

## Failure Injection

The retained run started from an empty projection and injected failure at `gameId=250001` with 1,000-row chunks.

Measured failed execution:

- JobInstance 6, JobExecution 7, status `FAILED`;
- StepExecution 7, status `FAILED`;
- read 251,000; write 250,000; commit 250; rollback 1;
- Read Model rows after failure: exactly 250,000;
- process exit: 1;
- JobExecution time: 12.2677 seconds; process elapsed: 15.47 seconds.

The stored ExecutionContext contains the paging sort key `id=250000` and read count 250,000. The failed chunk that encountered 250,001 rolled back, while earlier chunks remained committed and visible. This is partial data, not a successful rebuild.

## Restart Result

The restart used the same `runId`, mode, and bounds, changed only the non-identifying failure parameter to zero, and therefore created JobExecution 8 for the same JobInstance 6.

Measured restart:

- status `COMPLETED`;
- read/write 750,000, not 1,000,000;
- commit 751; rollback 0;
- JobExecution time 34.7788 seconds; process elapsed 37.48 seconds;
- final Read Model rows 1,000,000;
- exhaustive Source/projection equality and all three representative pages passed.

The two executions together wrote each logical range once. The final checker found zero missing, extra, or field-mismatched rows.

## Partial Backfill

The experiment deliberately increased `total_score` in projection rows for inclusive IDs 400,001–410,000, then ran only that Batch range.

Measured result:

- target rows read/written: 10,000;
- commits: 11; rollbacks: 0;
- JobExecution time: 0.6868 seconds; process elapsed: 3.64 seconds;
- checksum outside the range before/after: `2127689939751403`, unchanged;
- exhaustive one-million-row Source/projection equality passed afterward.

The outside checksum is supporting evidence, not a collision-proof equality proof. The exhaustive final comparison is the correctness authority.

## Correctness

Automated Testcontainers integration tests use 200 deterministic games and verify:

- normal chunk build and all projection fields;
- a failure after 50 committed rows;
- persisted FAILED status/counts;
- restart as the same JobInstance reading only the remaining 150 rows;
- no missing/mismatched projection after restart;
- 21-ID backfill, unchanged data outside the range, and final Source/projection equality.

The actual one-million-row run separately passed `check-stage2-read-model.sh` after normal Batch build, restart, and partial backfill. That check compares all eight projection fields for every game and compares the three representative paginated queries.

## Performance / Operational Comparison

Measured times distinguish framework JobExecution time, SQL-reported time, and whole-process time:

| Item | Simple baseline | Spring Batch |
| --- | --- | --- |
| Full processing | 385.5919 SQL s; 722.67 process s including checks | 312.2380 job s; 330.87 process s; checks run separately |
| Execution state | process output only | durable Job/Step status and timestamps |
| Failure position | unknown | ID 250001; read 251k/write 250k/commit 250/rollback 1 |
| Restart range | complete rebuild | remaining 750k in same JobInstance |
| Partial backfill | unsupported command; one-off SQL | explicit 10k ID range |
| Duplicate/missing after recovery | failed output incomplete | zero after exhaustive check |
| Operator procedure | rerun full script and checker | rerun same identifying parameters with failure disabled |
| Added complexity | one SQL and wrapper | dependency, nine metadata tables, job/step/reader/writer, parameters |

The single ordered timing sample is not evidence that Batch is inherently faster. The result does show the recovery trade-off: additional structure made committed progress and bounded work observable and reusable.

## Remaining Problems

Spring Batch did not solve whole-projection publication:

- Batch UPSERT leaves an existing complete row available while its chunk is refreshed, unlike the retained `TRUNCATE` baseline.
- Initial population from an empty table still exposes a growing partial projection.
- Different chunks do not share one database snapshot, so Source may change during a long run.
- An UPSERT-only full run does not remove a projection row whose Source game was deleted; the exhaustive checker detects that state, but the job does not repair it.
- There is no atomic all-or-nothing version switch. Versioned/shadow tables and atomic swap were not implemented.

Bulk processing also does not propagate ongoing Source inserts, corrections, status changes, or cancellations. Freshness remains limited by when an operator invokes a job.

## Decision

Spring Batch is justified for bulk/rebuild/recovery in this lab. Its metadata made status and failure position queryable, and its chunk checkpoint reduced restart from one million rows to the uncommitted 750,000-row suffix. Explicit bounds made a 10,000-row repair possible without touching the other 990,000 rows. Those capabilities address the Stage 2 evidence; the decision is not based on claiming a full-build speed win.

## Next Question

The remaining evidenced problem is freshness: a completed bulk job immediately begins aging as Source changes. Stage 4 entry is reasonable only after defining a required freshness target and comparing periodic bounded Batch work against continuous propagation cost. CDC and Kafka are candidates because the project design assigns them change-propagation responsibility, but this Stage does not establish that they are the only solution.

Atomic publication/stale-row removal is a separate candidate if the service requires a consistent whole-model version during rebuild. That problem must not be conflated with Batch restart or CDC freshness.

## Provenance

Tracked evidence is under `benchmarks/stage3/results/20260812T111000Z`:

- `metadata.txt`: UTC timestamps, commit, dirty status, tracked diff hash, jar hash, environment, seed, counts, and experiment coordinates;
- `source-manifest.sha256`: content hashes for build, application, tests, and scripts, including untracked Stage files;
- `raw/`: compact command output, failure exits/row counts, correctness checks, and JDBC execution/context rows;
- `summarized/`: correctness and operational comparison tables derived from raw evidence.

The runner writes only compact, reviewable evidence. Gradle outputs, the executable jar, MySQL data files, Docker logs, and other reproducible transient artifacts remain ignored or outside the result directory. The jar itself is not tracked; its SHA-256 is retained.

Spring Batch 6 reports that the selected legacy chunk builder path is deprecated for removal in Batch 7. This Stage stays on the Boot-selected Batch 6.0.4 API that produced the recorded evidence; migration to the supported replacement is required before a future Batch 7 upgrade and is not a Stage 3 recovery behavior change.
