# Game History Read Model Lab

[![Verify](https://github.com/winkrj/game-history-lab/actions/workflows/verify.yml/badge.svg)](https://github.com/winkrj/game-history-lab/actions/workflows/verify.yml)

게임 이력을 조회할 때마다 여러 테이블을 조인하고 집계하던 구조를, 조회 결과를 미리 계산한 테이블(Read Model)로 분리한 실험 프로젝트입니다. 100만 건의 게임 데이터로 조회 성능을 비교하고, 조회용 데이터를 **생성하고 실패 후 복구하며 원본 변경과 동기화하는 과정**까지 검증했습니다.

`Kotlin` · `Spring Boot` · `MySQL` · `Spring Batch` · `Debezium` · `Kafka`

아래 수치는 로컬 비교 실험 결과입니다. 조회 성능과 CDC 반영 지연은 서로 다른 실험에서 측정했으며, 운영 환경의 처리 용량을 뜻하지 않습니다.

| 3개월 조회 p95 | 요청당 읽은 행 | 원본 변경 반영 |
| ---: | ---: | ---: |
| 6.2~10.8초 → **6.96~10.49ms** | 289,842 → **20** | **p95 450ms** |

## 구조

조회 경로에서 조인과 집계를 줄이면 응답은 빨라지지만, 미리 계산한 데이터를 관리해야 하는 일이 남습니다. 최초 데이터를 만드는 작업, 중단된 작업을 복구하는 과정, 이후 원본 변경을 따라가는 역할을 나눴습니다.

![게임 이력 조회용 데이터 생성과 변경 반영 구조](docs/diagrams/read-model-operations.svg)

- **Spring Batch**는 최초 생성, 전체 재생성, 부분 복구를 담당합니다.
- **Debezium + Kafka**는 Batch 이후에도 이어지는 원본 변경을 보관하고 전달합니다.
- **CDC Consumer**는 이벤트에서 `gameId`만 꺼내 최신 원본을 다시 계산합니다.
- 조회 API는 `game_history_read_model`만 읽습니다.

## 설계 의도

### Spring Batch 기반 재시작과 부분 복구

`TRUNCATE → INSERT SELECT`는 단순하지만 작업 상태가 남지 않았습니다. Spring Batch의 JobRepository와 chunk checkpoint를 사용해 실패 지점부터 재시작하고, 필요한 범위만 다시 만들 수 있게 했습니다.

250,001번째 게임에서 작업을 중단하자 250,000건과 checkpoint가 남았습니다. 같은 작업을 다시 실행했을 때 이미 처리한 구간은 건너뛰고 나머지 750,000건만 처리했습니다.

### 주기 갱신의 한계와 Kafka 도입

변경이 드물고 5~10분 지연을 허용한다면 Incremental Batch가 더 단순합니다. 하지만 수 초 단위 반영을 위해 주기를 1분까지 줄이자 한 시간 동안 60회 실행 중 25회가 빈 작업이었고, 반영 지연도 약 59초였습니다.

이 요구에서만 Debezium과 Kafka의 운영 비용을 감수할 이유가 생겼습니다.

### 이벤트 기반 최신 원본 재계산

조회 결과는 `games`, `rounds`, `round_scores` 세 테이블의 조합입니다. CDC payload를 직접 합치지 않고, 이벤트에서는 영향받은 `gameId`만 찾은 뒤 원본의 최신 상태를 다시 읽어 한 행 전체를 UPSERT합니다.

같은 이벤트가 다시 전달돼도 현재 원본으로 덮어쓰기 때문에 결과가 달라지지 않습니다.

### 변경 누락을 방지하는 초기화 순서

`snapshot.mode=no_data` Connector를 Batch 뒤에 시작했을 때 그 사이의 변경 1건이 누락됐습니다. 순서를 `Connector 시작 → Batch 생성 → Consumer catch-up`으로 바꾼 뒤 lag 0과 전체 데이터 일치를 확인했습니다.

## 복구와 데이터 정합성 검증

| 시나리오 | 확인 결과 | 근거 |
| --- | --- | --- |
| 100만 건 처리 중 강제 중단 | 250,000건 이후부터 재시작, 최종 차이 0건 | [Batch 복구](docs/experiments/stage3-batch-recovery.md) |
| 10,000건 부분 재처리 | 대상 밖 990,000건 변경 없음 | [Batch 복구](docs/experiments/stage3-batch-recovery.md) |
| 원본 생성·상태·점수 변경 | p95 450ms, 최대 468ms, 누락 0건 | [CDC + Kafka](docs/experiments/stage5-cdc-kafka.md) |
| Consumer 트랜잭션 실패 | 롤백 후 재전달, 최종 결과 일치 | [트랜잭션 테스트](src/test/kotlin/lab/gamehistory/cdc/CdcConsumerTransactionIntegrationTests.kt) |
| Batch와 CDC 전환 중 변경 | catch-up 후 lag 0, 전체 값 일치 | [Handoff 실험](docs/experiments/batch-cdc-handoff.md) |

## 실험 범위와 한계

이 저장소는 로컬 환경에서 책임 분리와 실패 복구를 검증한 실험입니다. 아래 항목까지 해결한 운영 시스템이라고 주장하지 않습니다.

- 전체 재생성 결과의 원자적 공개
- 삭제와 하위 데이터 이동 처리
- 반복 실패 이벤트의 재시도와 별도 보관
- topic-partition 경계 영속화와 다중 broker 장애 복구

## 코드와 실험 기록

| 관심사 | 구현 | 기록 |
| --- | --- | --- |
| 대량 생성·복구 | [Batch 구성](src/main/kotlin/lab/gamehistory/batch/GameHistoryReadModelBatchConfiguration.kt) | [Stage 3](docs/experiments/stage3-batch-recovery.md) |
| 주기 갱신 | [Incremental Batch](src/main/kotlin/lab/gamehistory/batch/IncrementalGameHistoryBatchConfiguration.kt) | [Stage 4](docs/experiments/stage4-incremental-freshness.md) |
| 실시간 갱신 | [Kafka Consumer](src/main/kotlin/lab/gamehistory/cdc/GameHistoryCdcConsumer.kt) | [Stage 5](docs/experiments/stage5-cdc-kafka.md) |
| 공통 재계산 | [Projection Updater](src/main/kotlin/lab/gamehistory/projection/GameHistoryProjectionUpdater.kt) | [최종 비교](docs/final-comparison.md) |

JDK 21과 Docker Compose를 사용할 수 있는 환경에서 Docker를 실행한 뒤, 저장소 루트에서 다음 명령으로 빌드와 통합 테스트를 확인할 수 있습니다. 테스트에는 Testcontainers를 사용합니다.

```bash
./scripts/verify.sh
```

이 명령은 Compose 설정 검사와 Gradle `clean check`를 실행합니다. 100만 건 데이터 생성이나 성능 실험 전체를 실행하는 명령은 아닙니다. 단계별 준비와 실행 방법은 위 실험 기록을 따릅니다.
