# Batch → CDC handoff

## 문제

Debezium의 `snapshot.mode=no_data`는 커넥터가 시작된 이후의 변경만 전달합니다. Batch가 끝난 뒤 커넥터를 시작하면 그 사이 변경은 Kafka에 없기 때문에 Consumer가 복구할 수 없습니다.

## 선택한 순서

```text
Connector 시작
→ START barrier 변경이 Kafka에 기록됐는지 확인
→ Consumer를 멈춘 채 Batch 실행
→ Batch 이후 변경의 target offset 확인
→ Consumer 시작
→ target offset까지 catch-up
→ Source와 Read Model 전체 비교
```

설계에서는 Consumer가 최신 값을 쓴 뒤 Batch가 이전 값을 덮는 순서를 피하기 위해 둘을 동시에 실행하지 않습니다. 이번 실행에서 Source 변경은 Batch 완료 뒤 Consumer 시작 전에 발생시켰고, Kafka에 보관된 record를 Consumer가 읽어 최신 원본으로 다시 계산했습니다. Batch 실행 중 변경과 stale overwrite 자체는 이 결과의 검증 범위가 아닙니다.

## 실패와 수정 비교

1,000개 게임을 다시 만든 뒤 같은 변경을 두 순서로 실행했습니다.

| 순서 | Source | Read Model | 불일치 |
| --- | --- | --- | ---: |
| Batch → 변경 → Connector | `CANCELLED` | `COMPLETED` | 1 |
| Connector → Batch → 변경 → Consumer catch-up | `CANCELLED` | `CANCELLED` | 0 |

수정한 순서에서는 한 partition인 `games` topic에서 START barrier 이후 end offset `1`, Batch 이후 target offset `2`를 확인했습니다. Consumer는 초기화된 topic의 `earliest`부터 읽었습니다. 세 topic의 현재 끝까지 처리한 뒤 전체 lag는 `0`이었고, 1,000개 Source/Read Model 행의 전체 값이 일치했습니다.

- [결과 요약](../../benchmarks/handoff/results/20260901T1425Z/summary.tsv)
- [offset 경계](../../benchmarks/handoff/results/20260901T1425Z/offsets.tsv)
- [전체 정합성 확인](../../benchmarks/handoff/results/20260901T1425Z/safe-correctness.log)
- [실행 소스 manifest](../../benchmarks/handoff/results/20260901T1425Z/source-manifest.sha256)

## 검증 범위

이 순서는 insert/update가 최종 수렴하는지 확인한 로컬 실험입니다. 다음 문제는 별도입니다.

- Batch 중 API가 부분적으로 만들어진 데이터를 읽는 문제
- 삭제와 하위 데이터 이동
- Kafka/Connect 데이터의 재기동 내구성
- 반복 실패 이벤트의 격리와 재처리

운영 전환에서는 시작·목표 경계를 합계가 아닌 모든 topic-partition의 offset map으로 영속화하고, 기존 Consumer group의 재시작 위치와 Kafka retention을 함께 관리해야 합니다. 이 실험은 ephemeral broker와 매번 새로 만든 `earliest` group을 사용했으므로 그 내구성까지 증명하지 않습니다.

완성된 한 버전만 공개해야 한다면 동일 테이블 catch-up이 아니라 별도 Read Model 생성과 원자적 전환이 필요합니다.

## 재현

이 명령은 로컬 Source 데이터를 1,000건으로 다시 만들고 Kafka/Connect 컨테이너를 재생성합니다.

```bash
HANDOFF_SEED_GAME_COUNT=1000 ./scripts/run-handoff-experiment.sh <result-id>
```
