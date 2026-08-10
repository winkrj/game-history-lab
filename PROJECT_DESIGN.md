# Game History Read Model Lab — 간단 설계

## 1. 프로젝트 목적

실무에서 경험한 대량 게임 이력 조회 문제를 작은 환경에서 다시 만들고, Read Model을 적용하면서 새로 생기는 운영 문제를 Spring Batch와 CDC로 개선한다.

이 프로젝트의 목적은 가능한 아키텍처를 모두 비교하는 것이 아니다. 다음과 같이 **실제 문제를 발견하고 필요한 기술을 선택하는 흐름**을 만드는 것이다.

```text
대량 JOIN 조회가 느리다
→ Read Model로 조회 비용을 줄인다
→ 일별 갱신과 과거/당일 분리 조회가 복잡해진다
→ Spring Batch로 대량 처리와 재처리를 관리한다
→ CDC와 Kafka로 변경분을 계속 반영한다
→ 하나의 Read Model에서 전체 게임 이력을 조회한다
```

## 2. 핵심 질문

> 대량 게임 이력 조회를 위해 Read Model을 분리했을 때 발생하는 일별 갱신, 과거·당일 분리 조회, 실패 복구와 재처리 문제를 Spring Batch와 CDC로 어떻게 단순화할 수 있는가?

## 3. 기본 도메인

```text
Shop
 └─ Game
     └─ Round
         └─ RoundScore
```

대표 조회 API 하나를 기준으로 개발한다.

```text
GET /shops/{shopId}/games?from={from}&to={to}&page={page}&size={size}
```

조회 결과에는 최소한 다음 정보가 포함된다.

```text
gameId
shopId
playedAt
playerNickname
courseName
totalScore
roundCount
gameStatus
```

향후 Read Model은 `gameId`당 1 row인 projection으로 정의한다. 대표 조회 API에 필요한 값을 미리 계산해서 보관하며, 기본적인 결정적 정렬 기준은 다음과 같다.

```text
playedAt DESC, gameId DESC
```

구체적인 Read Model schema는 단계 2에서 결정한다.

UI, 인증·인가, 관리자 기능과 다양한 검색 기능은 만들지 않는다.

## 4. 개발 단계

### 단계 1 — Original JOIN 조회

정규화된 원본 테이블을 JOIN하고 집계해 게임 이력을 조회한다.

```text
Query API
  ↓
Game + Round + RoundScore
  ↓
JOIN + Aggregate
```

목표는 대량 데이터에서 조회 비용이 증가하는 문제를 빠르게 재현하는 것이다.

처음부터 여러 데이터 규모를 모두 만들지 않는다. 1M 내외로 시작하고 병목이 충분히 보이지 않을 때만 데이터를 늘린다.

확인할 항목:

- 조회 결과의 정확성
- 응답 시간 p95
- 처리량
- SQL 실행 계획
- DB가 읽은 row와 자원 사용량

완료 조건:

- 대표 API가 동작한다.
- 재현 가능한 테스트 데이터가 있다.
- JOIN 조회의 기준 성능과 실행 계획을 기록했다.
- 병목이 실제로 확인되었거나, 데이터 규모를 더 늘려야 한다는 판단 근거가 있다.

### 단계 2 — 과거 Read Model + 당일 원본 조회

실무에서 사용했던 방식과 유사한 구조를 만든다.

```text
과거 데이터 → Read Model
당일 데이터 → 원본 테이블 조회
              ↓
          API에서 Merge
```

과거 Read Model 생성은 처음부터 Spring Batch를 사용하지 않는다. plain SQL 또는 단순 application job으로 먼저 동작하게 만들고, 다음 운영 문제를 실제로 확인한다.

- 실행 상태 추적
- 중간 실패 위치
- restart
- 일부 기간 재처리
- 중복/누락 관리

이 문제를 확인한 뒤 단계 3에서 Spring Batch를 도입한다. Scheduler 자체는 별도의 장기 비교 대상으로 만들지 않는다.

먼저 조회 성능이 개선되는지 확인한다. 그다음 이 구조에서 발생하는 불편을 관찰한다.

예상되는 문제:

- 과거 데이터를 매일 가공해야 한다.
- 작업이 중간에 실패했을 때 처리 위치를 알기 어렵다.
- 전체 재실행과 일부 재처리의 기준이 불명확하다.
- 과거와 당일을 따로 조회하고 정렬·pagination 결과를 합쳐야 한다.
- 날짜 경계에서 누락이나 중복 가능성이 생긴다.
- 수정되거나 취소된 과거 이력의 반영 시점이 애매하다.

모든 문제를 억지로 구현하지 않는다. 실제 구현에서 확인된 문제만 결과로 기록한다.

완료 조건:

- Original JOIN과 동일한 결과를 반환한다.
- 조회 성능 차이를 확인했다.
- 과거/당일 merge가 만드는 코드 및 운영 복잡성을 설명할 수 있다.
- Spring Batch와 CDC가 해결해야 할 구체적인 문제가 확인되었다.

### 단계 3 — Spring Batch로 대량 처리와 재처리 관리

Spring Batch는 다음 책임만 가진다.

- 최초 Read Model 적재
- 과거 데이터 backfill
- 특정 기간 재처리
- 대량 데이터 재구축
- 중간 실패 후 restart

Scheduler와 Spring Batch를 세부 항목별로 장기간 비교하지 않는다. 기존 단순 작업의 불편을 확인하고, Spring Batch가 실행 상태와 재처리를 더 명확하게 만드는지만 검증한다.

최소 실패 실험:

```text
대량 처리 중 의도적으로 실패
→ 실패 위치 확인
→ restart
→ 누락·중복 없이 완료
```

확인할 항목:

- 전체 처리 시간
- 처리 건수와 실패 위치
- restart 시작점
- 재실행 후 중복·누락 여부
- 재처리 절차의 명확성

완료 조건:

- 최초 적재와 기간 backfill이 동작한다.
- 중간 실패와 restart를 한 번 이상 재현했다.
- 재시작 후 Source와 Read Model이 일치한다.
- Spring Batch를 사용하는 이유를 성능이 아닌 운영·복구 관점에서 설명할 수 있다.

### 단계 4 — CDC와 Kafka로 변경분 반영

CDC와 Kafka는 이미 정해진 기술을 사용하기 위해 도입하지 않는다. 단계 2~3에서 다음 중 하나 이상의 문제가 실제로 확인됐을 때 단계 4로 진행한다.

- periodic update에 의한 freshness gap
- 과거/당일 분리 조회와 API merge 복잡성
- 수정되거나 취소된 과거 데이터의 반영 어려움
- Batch 주기를 계속 줄였을 때의 처리 비용 또는 운영 복잡성

Spring Batch는 bulk, rebuild, recovery 책임을 유지한다. CDC와 Kafka는 지속적인 change propagation이 실제로 필요해졌을 때 도입한다.

단계 4에 진입하면 Source DB 변경을 CDC로 감지하고 Kafka를 통해 Read Model Consumer에 전달하는 구조를 목표로 한다.

```text
Source MySQL
  ↓ DB 변경
CDC
  ↓
Kafka
  ↓
Read Model Consumer
  ↓
Read Model
  ↓
Query API
```

초기 projection update 전략은 복잡한 stream join이 아니다. CDC 이벤트에서 영향을 받은 `gameId`를 식별한 뒤 Source DB의 최신 Game, Round, RoundScore 상태를 다시 조회하고, 해당 game의 Read Model row 전체를 재계산해 UPSERT한다. 이 전략을 기본값으로 사용하되 실제 구현 과정에서 문제가 확인되면 변경할 수 있다.

역할은 다음처럼 나눈다.

```text
Spring Batch = 최초 적재, backfill, 대량 재처리
CDC + Kafka = 이후 발생하는 변경분 전달
Read Model = 과거와 당일을 구분하지 않는 전체 조회
```

Kafka는 기술 사용 자체를 보여주기 위해 추가하지 않는다. CDC 변경 이벤트를 안정적으로 전달하고 재처리할 수 있는 통로로 사용한다.

이 단계의 상세 topic 구성, partition 수, retry, DLQ 정책은 지금 확정하지 않는다. 실제 구현을 시작할 때 필요한 만큼 결정한다.

최소 확인 항목:

- 신규 게임 이력이 Read Model에 반영된다.
- 수정·취소된 이력이 최종 상태로 반영된다.
- 같은 변경이 다시 전달되어도 결과가 깨지지 않는다.
- Consumer가 일시적으로 실패한 뒤 다시 처리할 수 있다.
- CDC 반영 후 과거/당일 분리 조회와 API merge를 제거할 수 있다.
- 최종 Read Model이 Source 기준 결과와 일치한다.

완료 조건:

- CDC 변경이 Kafka를 거쳐 Read Model에 반영된다.
- Query API가 하나의 Read Model만 조회한다.
- 최소 중복 전달과 Consumer 재시작을 검증했다.
- Spring Batch와 CDC/Kafka의 책임 차이를 설명할 수 있다.

## 5. 최소 측정 항목

처음부터 완전한 관측 플랫폼을 만들지 않는다. 다음 값만 우선 기록한다.

- Original JOIN과 Read Model의 조회 p95
- 조회 처리량과 오류율
- Spring Batch 전체 처리 시간
- 실패 후 restart 결과
- CDC 변경 발생부터 Read Model 반영까지 걸린 시간
- Source와 Read Model의 row count 및 핵심 집계 일치 여부

필요하면 이후에 p50, p99, DB CPU, Consumer lag 등의 지표를 추가한다.

## 6. 초기 범위에서 제외할 것

다음 내용은 실제 필요가 확인되기 전까지 구현하지 않는다.

- Redis cache
- Transactional Outbox 비교
- Versioned Read Model
- Dual Write 전략 비교
- 복잡한 Snapshot + Catch-up 구조
- 여러 retry/DLQ 방식 비교
- Kubernetes와 cloud 배포
- Microservice 분리
- 완성형 Prometheus/Grafana 대시보드
- 1M, 5M, 10M, 30M 전 구간 반복 측정
- 모든 장애 시나리오 구현

이 항목들은 프로젝트의 필수 단계가 아니라 후속 개선 후보로 둔다.

## 7. 개발 원칙

- 문제를 확인하기 전에 해결 기술을 추가하지 않는다.
- 다음 단계의 필요성이 확인될 정도로만 현재 단계를 구현한다.
- 중간 구조를 완성형 서비스처럼 과도하게 다듬지 않는다.
- 같은 결과를 비교할 수 있도록 대표 API와 데이터 의미를 유지한다.
- 측정하지 않은 성능 개선을 주장하지 않는다.
- 코드가 동작하는 것과 문제 개선이 확인된 것을 구분한다.
- 새로운 복잡성이 실제로 생겼을 때만 후속 설계를 추가한다.

## 8. 프로젝트 완료 모습

이 프로젝트는 모든 후보 기술을 사용했을 때가 아니라 다음 흐름을 코드와 결과로 설명할 수 있을 때 완료된다.

```text
1. 원본 JOIN 조회의 병목을 재현했다.
2. Read Model로 조회 성능을 개선했다.
3. 과거/당일 분리와 일별 갱신의 운영 문제를 확인했다.
4. Spring Batch로 최초 적재와 재처리를 관리했다.
5. CDC와 Kafka로 변경분을 반영했다.
6. 하나의 Read Model에서 전체 이력을 조회했다.
7. 조회 성능, restart, 변경 반영, 최종 정합성을 검증했다.
```

최종 결론은 “Spring Batch, CDC, Kafka를 사용했다”가 아니다.

> Read Model로 조회 비용을 줄인 뒤 새로 발생한 일별 갱신, 분리 조회, 실패 복구 문제를 확인했고, Spring Batch에는 대량 처리와 재처리를, CDC와 Kafka에는 지속적인 변경 반영을 맡겨 조회 경로와 운영 책임을 단순화했다.

이 문장을 실제 코드와 측정 결과로 뒷받침하는 것이 프로젝트의 최종 목표다.
