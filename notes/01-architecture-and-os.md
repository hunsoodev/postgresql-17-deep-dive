# PostgreSQL 아키텍처와 OS 프로세스 모델

## 한줄 요약

PostgreSQL은 클라이언트 요청마다 postmaster가 fork()로 독립적인 백엔드 프로세스를 생성하는 멀티프로세스 아키텍처를 사용하며, 공유 메모리와 IPC를 통해 프로세스 간 통신을 수행합니다.

> 📖 이 노트의 다이어그램은 [The Internals of PostgreSQL](https://www.interdb.jp/pg/)에서 가져왔습니다.

## 실습 환경

이 노트의 모든 실습은 `docker/` 디렉토리의 환경을 사용합니다.

```bash
# 실습 환경 시작
cd docker && docker compose up -d

# PostgreSQL 접속
docker exec -it pg17-lab psql -U labuser -d ecommerce

# 컨테이너 셸 접속 (OS 레벨 실습용)
docker exec -it pg17-lab bash
```

주요 설정값 (`docker/postgresql.conf`):
- `shared_buffers = 128MB`
- `max_connections = 100`
- `work_mem = 4MB`
- `log_statement = 'all'`

---

## 왜 알아야 하는가

### 성능 문제 진단의 출발점

프로덕션 환경에서 갑자기 응답이 느려졌을 때, `ps aux | grep postgres`로 프로세스 목록을 확인하면 수백 개의 백엔드 프로세스가 보일 수 있습니다. 이것이 정상인지, 문제인지 판단하려면 PostgreSQL의 프로세스 모델을 이해해야 합니다.

### 리소스 설정의 근거

`shared_buffers` 설정값이 OS 공유 메모리 한계를 초과하면 PostgreSQL이 시작조차 되지 않습니다. `shmmax`, `shmall` 같은 OS 커널 파라미터와 PostgreSQL 설정의 관계를 알아야 적절히 튜닝할 수 있습니다.

### 멀티테넌시 환경 설계

이커머스 플랫폼에서 동시 접속자 1만 명을 처리해야 한다면, 각각에 백엔드 프로세스를 할당할 것인가? Connection pooling을 쓸 것인가? 아키텍처를 이해해야 올바른 설계가 가능합니다.

### 장애 격리와 안정성

한 쿼리가 메모리를 과도하게 사용해도 다른 세션은 영향을 받지 않습니다. 프로세스 기반 아키텍처가 주는 격리 효과를 이해하면 시스템의 안정성을 더 잘 보장할 수 있습니다.

---

## 1. 클라이언트 요청 처리 전체 흐름

```
[클라이언트 애플리케이션]
         |
         | TCP/IP (5432) 또는 Unix Domain Socket
         v
    [postmaster 프로세스]
         |
         | fork() 시스템 콜
         v
    [postgres 백엔드 프로세스]
         |
         | 1. Parser (구문 분석)
         v
         | 2. Rewriter (규칙 적용)
         v
         | 3. Planner (실행 계획 생성)
         v
         | 4. Executor (실행)
         v
    [결과 반환]
```

### 단계별 상세 설명

**1단계: 클라이언트 연결**
- 클라이언트가 TCP 5432 포트 또는 Unix socket으로 연결 요청
- postmaster 프로세스가 listen() 상태로 대기 중

**2단계: 백엔드 프로세스 생성**
- postmaster가 fork() 시스템 콜로 자식 프로세스 생성
- 새 프로세스는 클라이언트와 1:1 매핑
- 인증 수행 (pg_hba.conf 규칙 적용)

**3단계: 쿼리 처리 파이프라인**
- **Parser**: SQL 문자열을 파싱 트리로 변환
- **Rewriter**: 뷰, 규칙 등을 적용해 쿼리 재작성
- **Planner**: 통계 정보를 바탕으로 최적 실행 계획 생성
- **Executor**: 실제로 데이터 접근 및 연산 수행

**4단계: 결과 반환 및 세션 유지**
- 결과를 클라이언트에 전송
- 연결이 유지되는 동안 백엔드 프로세스는 계속 살아있음
- 클라이언트가 연결을 끊으면 프로세스 종료

### ✅ 직접 확인: 쿼리 파이프라인 추적

```sql
-- Parser → Planner 결과를 EXPLAIN으로 확인
EXPLAIN (VERBOSE, COSTS)
SELECT u.email, COUNT(o.order_id) AS order_count
FROM users u
LEFT JOIN orders o ON u.user_id = o.user_id
WHERE u.created_at > CURRENT_DATE - INTERVAL '30 days'
GROUP BY u.email
HAVING COUNT(o.order_id) > 5
ORDER BY order_count DESC
LIMIT 10;

-- Executor까지 포함한 실제 실행 (ANALYZE 추가)
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.email, COUNT(o.order_id) AS order_count
FROM users u
LEFT JOIN orders o ON u.user_id = o.user_id
WHERE u.created_at > CURRENT_DATE - INTERVAL '30 days'
GROUP BY u.email
HAVING COUNT(o.order_id) > 5
ORDER BY order_count DESC
LIMIT 10;
```

---

## 2. OS 관점: 프로세스 모델

![Fig 2.1: PostgreSQL 프로세스 아키텍처](../docs/images/ch02/fig-2-01.png)
*PostgreSQL 프로세스 아키텍처 (postmaster, backend, background workers)*

> **🔍 그림 해설**
>
> PostgreSQL의 프로세스 구조를 호텔에 비유하면 이해하기 쉽습니다. 가장 중앙에 있는 postmaster는 호텔의 프런트 데스크 직원과 같습니다. 손님(클라이언트)이 도착하면 프런트 직원이 직접 서비스를 제공하는 것이 아니라, 각 손님마다 전담 집사(backend process)를 배정합니다. 이렇게 하면 한 손님의 문제가 다른 손님에게 영향을 주지 않죠. 그림 주변에 보이는 background writer, checkpointer, WAL writer 같은 프로세스들은 호텔의 유지보수 직원들입니다. 청소부(autovacuum)는 주기적으로 불필요한 것들을 정리하고, 보안 카메라 담당자(logger)는 모든 활동을 기록하며, 백업 발전기 관리자(WAL writer)는 만약의 사고에 대비합니다. 이들은 모두 shared memory라는 공용 게시판을 통해 정보를 공유합니다. 이런 구조 덕분에 한 세션에서 문제가 생겨도 전체 시스템이 멈추지 않습니다.

### postmaster의 역할

postmaster는 PostgreSQL의 "마스터" 프로세스로, 다음 역할을 수행합니다:

1. **서버 시작 시 초기화**
   - 공유 메모리 할당
   - 시스템 카탈로그 검증
   - 백그라운드 워커 프로세스 시작

2. **연결 수락 및 분배**
   - 클라이언트 연결을 listen
   - 각 연결마다 fork()로 백엔드 생성

3. **프로세스 감시**
   - 자식 프로세스 상태 모니터링
   - 비정상 종료 감지 및 복구

### ✅ 직접 확인: 프로세스 목록과 트리

컨테이너 셸에서:
```bash
# PostgreSQL 프로세스 목록
ps aux | grep postgres

# 프로세스 트리 (부모-자식 관계 확인)
ps auxf | grep postgres
```

예상 출력:
```
postgres     1  ...  postgres
postgres    10  ...  postgres: checkpointer
postgres    11  ...  postgres: background writer
postgres    12  ...  postgres: walwriter
postgres    13  ...  postgres: autovacuum launcher
postgres    14  ...  postgres: logical replication launcher
```

SQL로도 확인:
```sql
-- 현재 연결된 모든 프로세스
SELECT
    pid,
    backend_type,
    usename,
    application_name,
    client_addr,
    state,
    backend_start
FROM pg_stat_activity
ORDER BY backend_start;
```

### fork() 기반 프로세스 생성

PostgreSQL이 각 연결마다 새 프로세스를 fork하는 이유:

**장점:**
1. **메모리 격리**: 한 세션의 메모리 오버플로우가 다른 세션에 영향 없음
2. **크래시 격리**: 한 백엔드가 죽어도 다른 세션은 계속 동작
3. **보안**: 각 프로세스는 독립적인 주소 공간을 가짐
4. **이식성**: POSIX 표준으로 다양한 OS에서 동일하게 동작

**단점:**
1. **메모리 오버헤드**: 각 프로세스마다 최소 수 MB 사용
2. **컨텍스트 스위칭 비용**: 프로세스 전환은 스레드보다 무거움
3. **생성 비용**: fork()는 상대적으로 느림 (connection pooling으로 완화)

### 왜 쓰레드가 아닌 프로세스인가?

PostgreSQL이 처음 개발된 1990년대에는:
- 멀티스레딩이 OS마다 구현이 달랐음
- POSIX threads 표준이 불안정했음
- fork()가 더 안정적이고 이식성이 높았음

현재도 프로세스 모델을 유지하는 이유:
- **안정성**: 30년간 검증된 아키텍처
- **격리성**: 프로세스 격리가 주는 안전성
- **확장성**: 대부분 시나리오에서 충분한 성능
- **변경 비용**: 스레드 모델로 전환하려면 전체 재작성 필요

### ✅ 직접 확인: fork()로 백엔드 생성 관찰

**터미널 1** (컨테이너 셸 — 모니터링):
```bash
watch -n 1 'ps aux | grep "postgres:" | grep -v grep | wc -l'
```

**터미널 2** (호스트에서 — 다중 연결 생성):
```bash
# 5개 연결을 동시에 열고 각각 60초 대기
for i in $(seq 1 5); do
    docker exec pg17-lab psql -U labuser -d ecommerce -c "SELECT pg_sleep(60);" &
done
```

**터미널 3** (psql 안에서 — SQL로 확인):
```sql
SELECT pid, state, query
FROM pg_stat_activity
WHERE query LIKE '%pg_sleep%';
```

터미널 1에서 프로세스 수가 5개 늘어나는 것을 확인할 수 있습니다. 60초 후 연결이 끊기면 다시 줄어듭니다.

---

## 3. Background Workers 상세

PostgreSQL을 하나의 **식당**으로 비유하면 이해가 쉽습니다. postmaster는 매니저, backend process는 각 테이블 담당 웨이터입니다. 그런데 식당이 돌아가려면 웨이터만으로는 안 됩니다. 주방 뒤에서 묵묵히 일하는 사람들이 있는데, 그것이 background workers입니다. 이들이 각자의 주기로 동작하면서 backend process가 클라이언트 쿼리 처리에만 집중할 수 있게 합니다.

### checkpointer — "장부 정리 담당"

**하는 일:** 메모리(shared_buffers)에서 수정된 데이터(더티 페이지)를 디스크에 써주는 프로세스

**왜 필요한가:**
PostgreSQL은 성능을 위해 데이터를 바로 디스크에 쓰지 않습니다. 먼저 메모리에 수정하고 나중에 한꺼번에 디스크에 씁니다. 이 "한꺼번에 디스크에 쓰는 시점"이 checkpoint입니다. checkpoint가 없으면 서버가 비정상 종료될 때 WAL로부터 복구해야 하는 양이 너무 많아집니다.

> 편의점 알바가 매 거래마다 금고에 돈을 넣는 게 아니라, 일정 시간마다 계산대 돈을 모아서 금고에 넣는 것과 같습니다.

**트레이드오프:**
- checkpoint가 너무 자주 → 디스크 I/O 부하 증가
- checkpoint가 너무 드물 → 크래시 복구 시간 증가

**현재 실습 환경 설정** (`docker/postgresql.conf`):
```
checkpoint_timeout = 5min          -- 이 간격마다 checkpoint 발생
max_wal_size = 1GB                 -- WAL이 이 크기를 넘어도 checkpoint 발생
checkpoint_completion_target = 0.9 -- 체크포인트를 간격의 90%에 걸쳐 분산
```

**checkpoint는 한 번에 몰아서 쓰지 않는다:**

`checkpoint_completion_target = 0.9`는 다음 checkpoint까지 남은 시간의 90%, 즉 **4분 30초에 걸쳐 분산해서 쓴다**는 뜻입니다.

```
0분        4분30초    5분
|────쓰기 분산────|    |다음 checkpoint 시작
```

만약 분산 없이 한꺼번에 쓰면 디스크 I/O가 순간 폭증해서 그 시점에 실행 중인 쿼리들이 전부 느려집니다. 이것이 "checkpoint spike" 문제입니다.

**checkpoint가 발생하는 두 가지 조건:**

1. **시간 기반**: `checkpoint_timeout`(5분) 경과
2. **WAL 크기 기반**: WAL 파일 누적량이 `max_wal_size`(1GB) 초과

둘 중 먼저 해당되는 조건에서 checkpoint가 시작됩니다. 쓰기가 많은 워크로드에서는 5분이 안 되어도 WAL이 1GB를 넘으면 바로 발생합니다.

**"전부" 쓰는 건 맞는가?**

checkpoint 시점에 더티 페이지 전부를 디스크에 씁니다. 다만 bgwriter가 평소에 일부를 미리 써둔 상태이므로 실제로 checkpoint 때 써야 할 양은 줄어들어 있고, `completion_target` 덕분에 시간에 걸쳐 분산됩니다. 그래서 checkpointer와 bgwriter가 협력하는 구조입니다 — bgwriter가 평소에 조금씩 치워두고, checkpointer가 주기적으로 나머지를 마무리합니다.

### background writer (bgwriter) — "미리미리 정리하는 사람"

**하는 일:** checkpointer가 한꺼번에 쓰기 전에, 조금씩 미리 더티 페이지를 디스크에 써두는 프로세스

**왜 필요한가:**
checkpoint 시점에 수천 개의 더티 페이지를 한꺼번에 쓰면 디스크 I/O가 폭증합니다 (이걸 "checkpoint spike"라 합니다). bgwriter가 평소에 조금씩 써두면 checkpoint 때 부담이 줄어듭니다.

> 설거지를 한꺼번에 하면 힘드니까, 틈틈이 몇 개씩 씻어두는 것과 같습니다.

**checkpointer와의 차이:**

| | checkpointer | bgwriter |
|---|---|---|
| 언제 | 주기적 또는 WAL 초과 시 | 상시 조금씩 |
| 목적 | 복구 지점 확보 | I/O 부하 분산 |
| 대상 | 모든 더티 페이지 | 일부 더티 페이지 |

### WAL writer — "블랙박스 기록 담당"

**하는 일:** WAL(Write-Ahead Log) 버퍼의 내용을 WAL 파일(디스크)에 써주는 프로세스

**WAL이란:**
데이터를 실제로 변경하기 **전에** "이런 변경을 할 것이다"를 먼저 로그에 기록하는 것입니다. 서버가 갑자기 죽어도 이 로그를 보고 복구할 수 있습니다.

> 비행기 블랙박스처럼, 무슨 일이 있었는지 항상 기록해두는 역할입니다. 사고(크래시)가 나면 이걸 보고 복원합니다.

**WAL 파일은 실제로 존재하는 파일이다:**

디스크의 `pg_wal/` 디렉토리에 16MB짜리 파일들로 쌓입니다.

```
$PGDATA/pg_wal/
├── 000000010000000000000001   (16MB)
├── 000000010000000000000002   (16MB)
├── 000000010000000000000003   (16MB)
└── ...
```

**UPDATE 한 줄이 실행될 때의 전체 흐름:**

```
1. UPDATE users SET name = 'kim' WHERE id = 1;

2. [WAL 버퍼] (메모리)
   "id=1의 name을 'kim'으로 바꿀 것이다" ← 먼저 여기에 기록

3. [WAL 파일] (디스크 pg_wal/)
   WAL writer가 버퍼 내용을 디스크에 씀 ← 커밋 시 반드시 여기까지 완료

4. [shared_buffers] (메모리)
   실제 데이터 페이지를 메모리에서 수정

5. [데이터 파일] (디스크 base/)
   checkpointer/bgwriter가 나중에 디스크에 씀
```

핵심은 **3번이 5번보다 먼저**라는 것입니다. 실제 데이터는 아직 디스크에 안 썼더라도, "무엇을 바꿨는지" 로그가 디스크에 먼저 기록되어 있으니 크래시가 나도 복구할 수 있습니다.

**왜 데이터 파일에 바로 안 쓰고 WAL을 거치는가:**

데이터 파일은 테이블마다 다른 위치에 흩어져 있어서 랜덤 I/O가 발생합니다. 반면 WAL은 하나의 파일에 순서대로 append만 하니까 **순차 I/O**라서 훨씬 빠릅니다. 그래서 커밋할 때 WAL만 디스크에 쓰고, 실제 데이터 파일은 나중에 checkpointer가 한꺼번에 씁니다. 빠른 것(WAL)으로 안전성을 확보하고, 느린 것(데이터 파일)은 나중에 몰아서 처리하는 전략입니다.

**WAL 버퍼 → WAL 파일 사이에서 크래시가 나면?**

WAL 파일에 쓰기 전에 크래시가 나면 그 데이터는 유실됩니다. 그리고 이것은 **의도된 동작**입니다.

```
BEGIN;
UPDATE users SET name = 'kim' WHERE id = 1;
COMMIT;
```

| 크래시 시점 | 상태 | 결과 |
|---|---|---|
| COMMIT 전 | WAL 버퍼에만 있음 | 유실됨. 하지만 클라이언트도 `COMMIT OK`를 받지 못했으므로 트랜잭션이 없었던 것과 같음 |
| COMMIT 중 (WAL 쓰기 도중) | WAL 파일에 불완전하게 기록됨 | 복구 시 불완전한 레코드는 무시됨. 트랜잭션이 없었던 것과 같음 |
| COMMIT 완료 후 | WAL 파일에 완전히 기록됨, 데이터 파일은 아직 안 씀 | 복구 시 WAL을 읽어서 데이터 파일에 다시 반영 (redo). 데이터 보존됨 |

핵심 원칙: PostgreSQL이 클라이언트에게 `COMMIT OK`를 보내는 시점은 **WAL이 디스크에 완전히 기록된 후**입니다.

- `COMMIT OK`를 받았다 → WAL 파일에 써졌다 → 복구 가능
- `COMMIT OK`를 못 받았다 → 유실되더라도 클라이언트는 성공으로 간주하지 않음

클라이언트 입장에서 "성공했다고 들었는데 데이터가 없다"는 상황은 절대 발생하지 않습니다. 이것이 WAL의 핵심 보장입니다.

COMMIT 전에는 아직 롤백될 수 있는 데이터입니다. 확정되지 않은 것을 매번 디스크에 쓰는 건 낭비이므로, 메모리에만 두다가 COMMIT 시점에 한 번에 디스크로 flush합니다.

**왜 별도 프로세스(WAL writer)가 필요한가:**

각 backend가 커밋할 때마다 직접 WAL을 디스크에 쓰면 (fsync) 느립니다. WAL writer가 주기적으로 모아서 써주면 각 backend의 커밋 대기 시간이 줄어듭니다. "버퍼의 내용을 파일에 써준다"는 것은 메모리(WAL 버퍼)에 있는 로그를 디스크(WAL 파일)에 쓰는 것입니다. 매번 디스크에 직접 쓰면 느리니까, 먼저 메모리 버퍼에 모아뒀다가 WAL writer가 주기적으로 또는 커밋 시점에 디스크로 flush합니다.

### autovacuum launcher / worker — "청소부"

**하는 일:**
1. **dead tuple 정리** — UPDATE/DELETE 하면 이전 버전의 행이 바로 삭제되지 않고 남아있음 (MVCC 때문). 이걸 정리
2. **통계 갱신 (ANALYZE)** — planner가 좋은 실행 계획을 세우려면 "이 테이블에 행이 몇 개고, 값 분포가 어떤지" 알아야 함. 이 통계를 갱신
3. **Transaction ID wraparound 방지** — PostgreSQL의 트랜잭션 ID는 32비트(약 42억). 다 쓰면 데이터가 "미래에서 온 것"으로 보여서 사라짐. 이를 방지

**왜 이전 버전이 남아있는가 — MVCC 간략 설명:**

MVCC(Multi-Version Concurrency Control)란 데이터를 수정할 때 기존 버전을 덮어쓰지 않고 새 버전을 만드는 방식입니다. 이렇게 하면 읽기와 쓰기가 서로 블로킹하지 않습니다.

```
-- UPDATE users SET name = 'kim' WHERE id = 1; (트랜잭션 200번)
-- UPDATE는 내부적으로 DELETE + INSERT

행 A: { id=1, name='park', xmin=100, xmax=200 }  ← dead tuple (이전 버전)
행 B: { id=1, name='kim',  xmin=200, xmax=0 }    ← 새 버전 (유효)
```

- `xmin`: 이 행을 INSERT한 트랜잭션 ID
- `xmax`: 이 행을 DELETE/UPDATE한 트랜잭션 ID (0이면 유효)

이전 버전(행 A)은 바로 삭제되지 않습니다. 아직 이 행을 읽고 있는 다른 트랜잭션이 있을 수 있기 때문입니다. 아무도 더 이상 참조하지 않게 되면 autovacuum이 해당 공간을 재사용 가능하도록 정리합니다.

> MVCC에 대한 상세 내용은 `notes/04-transactions-and-mvcc.md`에서 다룹니다.

```sql
-- dead tuple 수 확인
SELECT relname, n_live_tup, n_dead_tup
FROM pg_stat_user_tables WHERE relname = 'users';

-- xmin, xmax 직접 확인
SELECT xmin, xmax, ctid, * FROM users WHERE user_id = 1;
```

**autovacuum을 끄거나 제대로 안 돌면:**
- 테이블 크기가 계속 커짐 (bloat)
- 쿼리 성능이 점점 떨어짐
- 최악의 경우 wraparound로 DB가 읽기 전용 모드로 전환됨

**launcher vs worker:**
- **launcher**: 어떤 테이블을 청소할지 판단하고 worker를 띄우는 관리자 (항상 1개)
- **worker**: 실제로 VACUUM/ANALYZE를 수행하는 프로세스 (최대 `autovacuum_max_workers`개)

> launcher는 청소 스케줄을 짜는 팀장, worker는 실제로 걸레 들고 닦는 사람입니다.

**현재 실습 환경 설정** (`docker/postgresql.conf`):
```
autovacuum = on
autovacuum_max_workers = 3
autovacuum_vacuum_scale_factor = 0.2
```

### logical replication launcher — "복제 관리자"

**하는 일:** 논리 복제(logical replication) 구독을 관리하는 프로세스

**논리 복제란:**
테이블 단위로 "이 테이블의 변경사항을 다른 DB로 보내줘"를 설정하는 것입니다. 물리 복제(streaming replication)가 디스크 블록 단위 복사라면, 논리 복제는 "INSERT/UPDATE/DELETE를 행 단위로 전달"합니다.

**언제 필요한가:**
- 서로 다른 PostgreSQL 버전 간 복제 (메이저 버전 업그레이드 시)
- 특정 테이블만 선택적으로 복제
- 양방향 복제가 필요할 때

복제를 안 쓰더라도 이 프로세스는 기본으로 떠 있으며, 리소스는 거의 사용하지 않습니다.

### logger (logging collector) — "CCTV 담당"

**하는 일:** 모든 로그 메시지를 파일로 기록

`logging_collector = on`이면 뜨는 프로세스입니다. 에러, 슬로우 쿼리, 접속 기록 등을 로그 파일에 씁니다.

### 면접 답변 예시

> "PostgreSQL의 background worker들은 각각 명확한 역할이 있습니다. checkpointer와 bgwriter는 메모리의 변경사항을 디스크에 쓰는 역할인데, checkpointer는 주기적으로 복구 지점을 만들고, bgwriter는 그 부담을 줄이기 위해 평소에 조금씩 써둡니다. WAL writer는 트랜잭션 안전성을 보장하는 WAL 로그를 디스크에 기록하고, autovacuum은 MVCC로 인해 남는 dead tuple을 정리하면서 통계도 갱신합니다. 이런 프로세스들이 각자의 주기로 동작하면서 backend process가 클라이언트 쿼리 처리에만 집중할 수 있게 해줍니다."

### ✅ 직접 확인: 백그라운드 워커 모니터링

```sql
-- checkpointer 통계
-- ⚠️ PostgreSQL 17 변경사항:
--   pg_stat_checkpointer는 17에서 신규 추가된 뷰입니다.
--   16 이하에서는 이 정보가 pg_stat_bgwriter에 포함되어 있었습니다.
--   (num_timed, num_requested, write_time, sync_time, buffers_written 등이
--    pg_stat_bgwriter에서 pg_stat_checkpointer로 분리됨)
SELECT
    num_timed AS timed_checkpoints,
    num_requested AS requested_checkpoints,
    write_time,
    sync_time,
    buffers_written
FROM pg_stat_checkpointer;

-- bgwriter 통계
-- ⚠️ PostgreSQL 17 변경사항:
--   17부터 checkpoint 관련 컬럼이 제거되고 bgwriter 고유 통계만 남았습니다.
--   16 이하: checkpoints_timed, checkpoints_req 등이 여기에 있었음
SELECT
    buffers_clean,
    buffers_alloc
FROM pg_stat_bgwriter;

-- autovacuum 워커 확인
SELECT pid, query_start, state, query
FROM pg_stat_activity
WHERE backend_type = 'autovacuum worker';
```

autovacuum을 강제로 트리거해서 관찰:
```sql
-- 대량 삭제로 dead tuple 생성
CREATE TABLE vacuum_test (id INT, data TEXT);
INSERT INTO vacuum_test SELECT i, repeat('x', 100) FROM generate_series(1, 10000) i;
DELETE FROM vacuum_test WHERE id % 2 = 0;

-- 잠시 후 autovacuum worker가 나타나는지 확인
SELECT pid, query FROM pg_stat_activity WHERE backend_type = 'autovacuum worker';

-- 정리
DROP TABLE vacuum_test;
```

---

## 4. OS 관점: 공유 메모리

![Fig 2.2: PostgreSQL 메모리 아키텍처](../docs/images/ch02/fig-2-02.png)
*PostgreSQL 메모리 아키텍처 (shared memory vs local memory)*

> **🔍 그림 해설**
>
> 이 그림은 PostgreSQL이 메모리를 어떻게 나누어 사용하는지 보여줍니다. 사무실 건물을 떠올려 보세요. 각 직원(backend process)은 자신만의 책상(local memory)을 가지고 있습니다. work_mem은 정렬이나 계산을 할 때 사용하는 개인 메모장이고, temp_buffers는 임시로 뭔가를 적어두는 포스트잇 같은 것입니다. 하지만 회사 전체가 함께 사용하는 공간도 있습니다. shared_buffers는 모든 직원이 함께 보는 공용 서류 캐비닛입니다. 여기에는 자주 참조하는 데이터 페이지들이 저장되어 있어서, 매번 디스크에서 읽어오지 않아도 됩니다. WAL buffer는 모든 변경사항을 기록하는 공용 메모장이고, commit log(CLOG)는 어떤 트랜잭션이 완료되었는지 기록하는 공용 체크리스트입니다.

### 세그먼트와 페이지 — 용어 정리

**가상 메모리 페이지:**

OS는 물리 메모리(RAM)를 일정한 크기의 조각으로 나눠서 관리합니다. 이 조각 하나가 **페이지**이고, Linux에서는 기본 **4KB**입니다. 프로세스마다 메모리 전체를 통째로 할당하면 낭비가 심하므로, 4KB 단위로 잘라서 필요한 만큼만 할당하고 안 쓰는 부분은 디스크로 내보낼 수(swap) 있습니다.

```
물리 메모리 (RAM 16GB)
┌──────┬──────┬──────┬──────┬─── ...
│ 4KB  │ 4KB  │ 4KB  │ 4KB  │
│페이지│페이지│페이지│페이지│
└──────┴──────┴──────┴──────┴─── ...
```

**공유 메모리 세그먼트:**

세그먼트는 **여러 프로세스가 함께 접근할 수 있는 연속된 메모리 영역**입니다. 일반적으로 각 프로세스는 자기만의 메모리 공간을 가지고 있어서 다른 프로세스의 메모리를 볼 수 없습니다. 하지만 PostgreSQL은 backend 프로세스들이 shared_buffers 같은 데이터를 공유해야 하므로, OS에 "이 메모리 영역은 여러 프로세스가 함께 쓸 수 있게 해줘"라고 요청해서 만드는 것이 공유 메모리 세그먼트입니다.

```
프로세스 A (backend)     프로세스 B (backend)     프로세스 C (bgwriter)
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│ 개인 메모리  │         │ 개인 메모리  │         │ 개인 메모리  │
│ (work_mem)  │         │ (work_mem)  │         │  (work_mem) │
└──────┬──────┘         └──────┬──────┘         └──────┬──────┘
       │                       │                       │
       └───────────┬───────────┴───────────────────────┘
                   │
                   ▼
    ┌──────────────────────────────┐
    │   공유 메모리 세그먼트         │
    │                              │
    │  shared_buffers (128MB)      │  ← 모든 프로세스가 같은 영역을 봄
    │  WAL buffers                 │
    │  CLOG buffers                │
    │  Lock tables                 │
    └──────────────────────────────┘
```

**"페이지"라는 단어가 두 가지 의미로 쓰인다:**

| 용어 | 맥락 | 크기 | 의미 |
|---|---|---|---|
| 페이지 (page) | OS 가상 메모리 | 4KB (Linux 기본) | 메모리 관리 최소 단위 |
| 페이지/블록 (page/block) | PostgreSQL 데이터 | 8KB (기본) | 테이블/인덱스 데이터 저장 단위 |

이 공유 메모리 섹션에서 `shmall`의 페이지는 OS 페이지(4KB)를 말하고, `shared_buffers`나 `EXPLAIN BUFFERS`에서 말하는 페이지는 PostgreSQL 블록(8KB)입니다.

### shared_buffers가 올라가는 구조

```
┌─────────────────────────────────────┐
│        OS 물리 메모리 (RAM)          │
├─────────────────────────────────────┤
│                                     │
│  ┌───────────────────────────────┐ │
│  │   System V Shared Memory      │ │
│  │                               │ │
│  │  ┌─────────────────────────┐ │ │
│  │  │   shared_buffers        │ │ │
│  │  │  (PostgreSQL 버퍼 풀)    │ │ │
│  │  │                         │ │ │
│  │  │  - 데이터 페이지 캐시    │ │ │
│  │  │  - 인덱스 페이지 캐시    │ │ │
│  │  │  - Buffer descriptors   │ │ │
│  │  │  - Lock tables          │ │ │
│  │  └─────────────────────────┘ │ │
│  │                               │ │
│  │  + WAL buffers                │ │
│  │  + CLOG buffers               │ │
│  └───────────────────────────────┘ │
│                                     │
│  + 각 백엔드 프로세스 메모리          │
│    (work_mem, maintenance_work_mem) │
└─────────────────────────────────────┘
```

### System V Shared Memory vs mmap

PostgreSQL은 전통적으로 **System V Shared Memory**를 사용했습니다:

```c
// PostgreSQL 내부 코드 (단순화)
int shmid = shmget(key, size, IPC_CREAT | 0600);
void *addr = shmat(shmid, NULL, 0);
```

**System V 공유 메모리의 특징:**
- 커널이 관리하는 영구적인 메모리 영역
- 프로세스가 죽어도 남아있음 (명시적으로 삭제 필요)
- `ipcs`, `ipcrm` 명령으로 관리

**최근 PostgreSQL은 mmap도 지원:**
- 더 현대적인 방식
- 파일을 메모리에 매핑
- 프로세스 종료 시 자동 정리

### shmmax와 shmall 설정

> 💡 Docker 환경에서는 `shm_size: "256m"` (docker-compose.yml)으로 공유 메모리 상한을 설정합니다. 실제 Linux 서버에서는 아래 커널 파라미터를 직접 조정해야 합니다.

**Linux에서 확인:**
```bash
# 최대 단일 공유 메모리 세그먼트 크기 (bytes)
cat /proc/sys/kernel/shmmax

# 시스템 전체 공유 메모리 페이지 수
cat /proc/sys/kernel/shmall

# 페이지 크기 확인
getconf PAGE_SIZE
```

**설정 계산:**
- `shared_buffers = 4GB`를 사용하려면
- `shmmax >= 4GB + 약간의 오버헤드` 필요
- `shmall >= shmmax / PAGE_SIZE`

**영구 설정 (/etc/sysctl.conf):**
```
kernel.shmmax = 17179869184  # 16GB
kernel.shmall = 4194304      # 16GB / 4096
```

### ✅ 직접 확인: 공유 메모리

컨테이너 셸에서:
```bash
# System V 공유 메모리 세그먼트
ipcs -m

# 세마포어
ipcs -s
```

SQL로 확인:
```sql
-- shared_buffers 설정 확인
SELECT
    name,
    setting,
    unit,
    pg_size_pretty(setting::bigint *
        CASE unit WHEN '8kB' THEN 8192 WHEN 'kB' THEN 1024 WHEN 'MB' THEN 1048576 ELSE 1 END
    ) AS size
FROM pg_settings
WHERE name IN ('shared_buffers', 'work_mem', 'maintenance_work_mem', 'wal_buffers', 'effective_cache_size');

-- 버퍼 풀 히트율 (shared_buffers가 잘 작동하는지)
SELECT
    sum(heap_blks_read) AS heap_read,
    sum(heap_blks_hit) AS heap_hit,
    CASE WHEN sum(heap_blks_hit) + sum(heap_blks_read) > 0
        THEN round(sum(heap_blks_hit)::numeric / (sum(heap_blks_hit) + sum(heap_blks_read)), 4)
        ELSE 0
    END AS hit_ratio
FROM pg_statio_user_tables;
-- hit_ratio > 0.99가 이상적
```

---

## 5. OS 관점: IPC (Inter-Process Communication)

### 세마포어 (Semaphores)

**세마포어란:** 카운터 기반의 동기화 도구입니다. "지금 이 자원을 몇 개까지 동시에 쓸 수 있는가"를 숫자로 관리합니다.

```
세마포어 값 = 3 (동시에 3개 프로세스 허용)

프로세스 A: wait() → 값 2로 감소 → 진입
프로세스 B: wait() → 값 1로 감소 → 진입
프로세스 C: wait() → 값 0으로 감소 → 진입
프로세스 D: wait() → 값 0이라 대기... 블로킹

프로세스 A: signal() → 값 1로 증가
프로세스 D: → 값 0으로 감소 → 진입 가능
```

**왜 뮤텍스가 아닌 세마포어인가:**

| | 뮤텍스 (Mutex) | 세마포어 (Semaphore) |
|---|---|---|
| 기본 범위 | **같은 프로세스 내** 스레드 간 동기화 | **서로 다른 프로세스** 간 동기화 가능 |
| 소유권 | 잠근 스레드만 풀 수 있음 | 누구나 signal 가능 |
| 카운터 | 1 (잠김/풀림) | N개 (동시에 N개 허용 가능) |

PostgreSQL은 멀티프로세스 아키텍처이므로 프로세스 경계를 넘을 수 있는 세마포어가 필요합니다. 뮤텍스는 기본적으로 같은 프로세스 안의 스레드 간에서만 동작합니다.

**PostgreSQL에서 필요한 세마포어 수:**

프로세스(연결)당 세마포어 1개를 할당합니다:

```
필요한 세마포어 수 = max_connections           (100)
                   + autovacuum_max_workers    (3)
                   + max_wal_senders           (10, 기본값)
                   + max_worker_processes      (8, 기본값)
                   + 7 (내부 프로세스용)
                   = 128개
```

이 세마포어들은 19개씩 세트로 묶여서 관리됩니다 (20번째는 매직넘버 검증용):

```
세마포어 세트 1: [sem0, sem1, ..., sem18, magic]  ← 19개 + 검증용 1개
세마포어 세트 2: [sem0, sem1, ..., sem18, magic]
...
필요한 세트 수 = ceil(128 / 19) = 7세트
```

**플랫폼별 차이 (공식 문서):**
- **Linux**: POSIX 세마포어 사용 → 커널 파라미터 제한 없음, 별도 설정 불필요
- **macOS, 이전 FreeBSD 등**: System V 세마포어 사용 → `SEMMNI`, `SEMMNS` 커널 파라미터 조정 필요

**세마포어의 역할 — 프로세스를 재우고 깨우는 메커니즘:**

세마포어 자체가 직접 데이터를 보호하는 게 아니라, 프로세스를 sleep/wake 시키는 기반입니다. PostgreSQL은 그 위에 여러 계층의 락을 구축합니다.

### 락(Lock) 계층 구조

PostgreSQL은 세마포어 위에 4단계 락 계층을 두고 있습니다. 아래로 갈수록 가볍고 짧게 잡고, 위로 갈수록 무겁고 오래 잡습니다.

**1단계: SpinLock — "문 앞에서 제자리 뛰기"**

가장 가벼운 락입니다. 락을 못 잡으면 sleep하지 않고 CPU에서 계속 루프를 돌면서(busy-wait) 기다립니다.

```
프로세스 A: 락 잡음 → 아주 짧은 작업 (변수 하나 수정) → 락 해제
프로세스 B: 못 잡음 → while(잠김) { 계속 확인... } → 잡음!
```

- 용도: 공유 변수 하나를 원자적으로 수정할 때 (몇 마이크로초)
- 특징: 대기 중에도 CPU를 놓지 않음. 오래 잡으면 CPU 낭비
- 비유: 화장실 문 앞에서 "아직인가? 아직인가?" 계속 노크하는 것

**2단계: LWLock (Lightweight Lock) — "shared_buffers 내부 교통정리"**

shared_buffers 안의 개별 버퍼 페이지 접근을 동기화합니다. SpinLock보다 오래 잡을 수 있고, 못 잡으면 sleep합니다.

```
프로세스 A: LWLock(Shared) 잡음 → 버퍼 페이지 읽기
프로세스 B: LWLock(Shared) 잡음 → 같은 페이지 읽기 (동시에 가능!)
프로세스 C: LWLock(Exclusive) 요청 → A, B가 끝날 때까지 sleep
```

- 용도: 버퍼 페이지 읽기/쓰기, WAL 버퍼 접근, 카탈로그 캐시 등
- 특징: **Shared 모드(읽기)는 여러 프로세스가 동시에 잡을 수 있고, Exclusive 모드(쓰기)는 혼자만 가능**
- 비유: 도서관 열람실. 읽기는 여러 명이 동시에 가능하지만, 책 내용을 수정하려면 혼자 독점해야 함

**3단계: 행 락 (Row Lock) — "이 행은 내가 수정 중"**

특정 행(tuple)에 대한 동시 수정을 방지합니다. SQL의 `FOR UPDATE`, `FOR SHARE`로 명시적으로 잡거나, UPDATE/DELETE 시 자동으로 잡힙니다.

```sql
-- 세션 A
BEGIN;
SELECT * FROM users WHERE user_id = 1 FOR UPDATE;  -- user_id=1 행에 락
-- 아직 커밋 안 함

-- 세션 B
UPDATE users SET username = 'test' WHERE user_id = 1;  -- 대기... (A가 끝날 때까지)
UPDATE users SET username = 'test' WHERE user_id = 2;  -- 즉시 실행 (다른 행)
```

- 용도: UPDATE, DELETE, SELECT FOR UPDATE
- 특징: **행 단위이므로 다른 행은 영향 없음**. 테이블 전체를 잠그지 않음
- 비유: 엑셀 공유 문서에서 특정 셀을 편집 중이면 그 셀만 잠기고, 다른 셀은 자유롭게 편집 가능

**4단계: 테이블 락 (Table Lock) — "이 테이블에 대한 접근 규칙"**

테이블 전체에 대한 동시 접근을 조율합니다. 8가지 모드가 있으며, 일반 쿼리에서는 가장 약한 락이 자동으로 걸립니다.

| 상황 | 걸리는 락 | 허용 | 블로킹 |
|---|---|---|---|
| `SELECT` | AccessShareLock | 다른 SELECT, UPDATE 모두 허용 | `DROP TABLE`만 막음 |
| `UPDATE` | RowExclusiveLock | 다른 SELECT 허용 | `ALTER TABLE`, `DROP TABLE` 막음 |
| `ALTER TABLE` | AccessExclusiveLock | **모든 접근 차단** | SELECT까지 막음 |

- 핵심: 일반적인 SELECT와 UPDATE는 서로 블로킹하지 않음 (MVCC 덕분)
- 위험한 순간: `ALTER TABLE`이나 `DROP TABLE`은 모든 접근을 막으므로 프로덕션에서 주의

**전체 그림 — 락들이 협력하는 구조:**

```
SELECT * FROM users WHERE user_id = 1;

1. [테이블 락]  AccessShareLock on users      ← DROP TABLE 방지
2. [LWLock]    shared_buffers에서 해당 페이지 찾기 (Shared 모드)
3. [SpinLock]  버퍼 디스크립터 상태 확인 (마이크로초)
4. 데이터 반환

UPDATE users SET name = 'kim' WHERE user_id = 1;

1. [테이블 락]  RowExclusiveLock on users     ← ALTER TABLE 방지
2. [행 락]     user_id=1 행에 exclusive lock  ← 다른 UPDATE 방지
3. [LWLock]    버퍼 페이지 수정 (Exclusive 모드)
4. [SpinLock]  WAL 버퍼 포인터 갱신 (마이크로초)
5. WAL 기록 → 완료
```

**면접 답변 예시:**

> "PostgreSQL의 락은 4단계 계층으로 되어 있습니다. 가장 아래에는 SpinLock이 있어서 공유 변수 수정 같은 마이크로초 단위 작업을 busy-wait으로 동기화합니다. 그 위에 LWLock이 있어서 shared_buffers 내부의 버퍼 페이지 접근을 Shared/Exclusive 모드로 제어합니다. 행 락은 특정 행의 동시 수정을 방지하되 다른 행에는 영향을 주지 않고, 테이블 락은 DDL과 DML 간의 충돌을 조율합니다. 일반적인 SELECT와 UPDATE는 서로 블로킹하지 않는데, 이는 MVCC 덕분입니다. 이 모든 락의 기반에는 OS 세마포어가 있어서 프로세스를 sleep/wake 시키는 역할을 합니다."

### 시그널 (Signals)

postmaster와 백엔드 간 통신에 시그널을 사용합니다.

**주요 시그널:**
- `SIGTERM`: 정상 종료 (smart shutdown)
- `SIGINT`: 빠른 종료 (fast shutdown)
- `SIGQUIT`: 즉시 종료 (immediate shutdown)
- `SIGHUP`: 설정 재로드
- `SIGUSR1`: 체크포인트 요청

### ✅ 직접 확인: 설정 재로드

```sql
-- SQL에서 설정 재로드 (SIGHUP과 동일한 효과)
SELECT pg_reload_conf();

-- 재로드 후 설정 확인
SHOW work_mem;
```

---

## 6. 쿼리 처리 파이프라인 상세

### Parser (구문 분석기)

**입력:** SQL 문자열
**출력:** Parse Tree (파싱 트리)

```sql
SELECT u.username, COUNT(o.order_id)
FROM users u
JOIN orders o ON u.user_id = o.user_id
WHERE o.created_at > '2024-01-01'
GROUP BY u.username;
```

**파싱 트리 구조 (단순화):**
```
SelectStmt
├─ targetList: [u.username, COUNT(o.order_id)]
├─ fromClause
│  ├─ RangeVar: users (alias: u)
│  └─ JoinExpr
│     ├─ left: orders (alias: o)
│     └─ condition: u.user_id = o.user_id
├─ whereClause: o.created_at > '2024-01-01'
└─ groupClause: [u.username]
```

**검증 사항:**
- 문법 오류
- 테이블/컬럼 존재 여부
- 타입 호환성
- 권한 확인

### Rewriter (재작성기)

**역할:**
- 뷰를 실제 테이블 쿼리로 변환
- 규칙(RULE) 적용
- 파티션 프루닝 정보 추가

**예시: 뷰 확장**
```sql
-- 뷰 정의
CREATE VIEW active_users AS
SELECT * FROM users WHERE is_active = true;

-- 쿼리
SELECT * FROM active_users WHERE email = 'user1@example.com';

-- 재작성 후 (내부적으로)
SELECT * FROM users
WHERE is_active = true AND email = 'user1@example.com';
```

### Planner (실행 계획기)

**고려 사항:**

1. **통계 정보**
   - 테이블 행 수 (pg_class.reltuples)
   - 컬럼 분포 (pg_stats)
   - 인덱스 선택도

2. **비용 계산** — 현재 실습 환경 값 (`docker/postgresql.conf`):
   - `random_page_cost = 1.1` (SSD 환경)
   - `effective_io_concurrency = 200` (SSD 병렬 I/O)

3. **조인 전략**
   - Nested Loop: 작은 테이블 × 인덱스 조회
   - Hash Join: 중간 크기 테이블
   - Merge Join: 정렬된 데이터

### Executor (실행기)

**실행 모델:**
```
1. ExecInit: 리소스 할당, 인덱스 열기
2. ExecProcNode: 다음 튜플 가져오기 (재귀적 호출)
3. ExecEnd: 리소스 정리
```

**메모리 사용:**
- `work_mem` (현재 4MB): 정렬, 해시 작업
- `temp_buffers`: 임시 테이블

### ✅ 직접 확인: Rewriter 동작

```sql
-- 뷰 생성
CREATE VIEW active_users AS
SELECT * FROM users WHERE is_active = true;

-- 뷰에 대한 쿼리 계획을 보면 rewriter가 뷰를 풀어낸 것을 확인
EXPLAIN SELECT * FROM active_users WHERE email = 'user1@example.com';
-- Filter에 is_active = true AND email = '...' 둘 다 나타남

DROP VIEW active_users;
```

---

## 7. 프로세스 메모리 레이아웃

각 PostgreSQL 백엔드 프로세스는 다음과 같은 메모리 구조를 가집니다:

```
┌─────────────────────────────────┐  높은 주소
│     커널 공간 (Kernel Space)     │
├─────────────────────────────────┤
│     스택 (Stack)                 │  ← 함수 호출, 로컬 변수
│         ↓                        │
│                                  │
│     힙 (Heap)                    │  ← malloc으로 할당
│         ↑                        │
├─────────────────────────────────┤
│     BSS (초기화 안 된 데이터)     │
│     Data (초기화된 전역 변수)     │
│     Text (실행 코드)              │
├─────────────────────────────────┤
│  공유 메모리 매핑 영역            │  ← shared_buffers 접근
└─────────────────────────────────┘  낮은 주소
```

### ✅ 직접 확인: 프로세스 메모리 사용량

컨테이너 셸에서:
```bash
# postmaster 메모리
PID=$(pgrep -o postgres)
cat /proc/$PID/status | grep -E 'VmSize|VmRSS|VmData'

# 백엔드 프로세스 메모리
BACKEND_PID=$(pgrep -P $PID | head -1)
cat /proc/$BACKEND_PID/status | grep -E 'VmSize|VmRSS|VmData'
```

- **VmSize**: 가상 메모리 전체 크기
- **VmRSS**: 실제 물리 메모리 사용량
- **VmData**: 힙 영역 크기

---

## 8. 실무 모니터링 쿼리

### 오래 실행 중인 쿼리 찾기

```sql
SELECT
    pid,
    now() - query_start AS duration,
    usename,
    state,
    substring(query, 1, 100) AS query_snippet
FROM pg_stat_activity
WHERE state = 'active'
  AND query_start < now() - interval '5 minutes'
ORDER BY duration DESC;
```

### idle in transaction 찾기 (위험!)

```sql
SELECT
    pid,
    now() - state_change AS idle_duration,
    usename,
    substring(query, 1, 100) AS query_snippet
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND state_change < now() - interval '1 minute'
ORDER BY idle_duration DESC;

-- 이런 세션은 락을 잡고 있을 수 있어 위험
-- 필요시 종료:
-- SELECT pg_terminate_backend(pid);
```

### 락 대기 분석

```sql
SELECT
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    substring(blocked_activity.query, 1, 80) AS blocked_statement,
    substring(blocking_activity.query, 1, 80) AS blocking_statement
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks
    ON blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
    AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
    AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
    AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;
```

### 프로세스 강제 종료

```sql
-- 우아한 종료 (현재 쿼리만 취소)
SELECT pg_cancel_backend(1234);

-- 강제 종료 (세션 자체 종료)
SELECT pg_terminate_backend(1234);

-- 특정 사용자의 모든 세션 종료
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = 'labuser' AND pid != pg_backend_pid();
```

### ✅ 직접 확인: 프로세스 격리 테스트

**세션 1:**
```sql
BEGIN;
SELECT * FROM users WHERE user_id = 1 FOR UPDATE;
-- 커밋하지 않고 대기
```

**세션 2:**
```sql
-- 같은 행 업데이트 시도 (블로킹됨)
UPDATE users SET username = 'test_update' WHERE user_id = 1;
```

**세션 3** (모니터링):
```sql
-- 락 대기 상황 확인
SELECT
    blocked.pid AS blocked_pid,
    blocked.state,
    substring(blocked.query, 1, 60) AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.state,
    substring(blocking.query, 1, 60) AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_locks blocked_locks ON blocked.pid = blocked_locks.pid AND NOT blocked_locks.granted
JOIN pg_locks blocking_locks
    ON blocking_locks.relation = blocked_locks.relation
    AND blocking_locks.pid != blocked_locks.pid
    AND blocking_locks.granted
JOIN pg_stat_activity blocking ON blocking.pid = blocking_locks.pid;
```

세션 1에서 `ROLLBACK;`을 실행하면 세션 2의 UPDATE가 즉시 진행됩니다.

---

## 9. 실무 팁

### Connection Pooling은 필수

**문제:**
- 웹 애플리케이션에서 각 요청마다 새 연결 생성
- fork() 오버헤드 + 인증 오버헤드
- 수천 개 동시 연결 시 메모리 고갈

**해결 — 애플리케이션 레벨:**
```javascript
// Node.js에서 pg-pool 사용
const { Pool } = require('pg');
const pool = new Pool({
  host: 'localhost',
  database: 'ecommerce',
  user: 'labuser',
  password: 'labpass',
  max: 20,                    // 최대 20개 연결 유지
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

const result = await pool.query('SELECT * FROM users WHERE user_id = $1', [userId]);
```

**해결 — 외부 풀러 (PgBouncer):**
```ini
# pgbouncer.ini
[databases]
ecommerce = host=localhost port=5432 dbname=ecommerce

[pgbouncer]
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
```

### max_connections 설정 전략

**공식:**
```
max_connections = (available_ram - shared_buffers - OS) / work_mem
```

현재 실습 환경 (Docker 메모리 제한 1GB):
- shared_buffers: 128MB
- OS + 기타: ~200MB
- work_mem: 4MB
- → 최대 약 170개, 현재 설정: `max_connections = 100`

### idle in transaction 방지

```sql
-- 10분 이상 idle in transaction 상태면 자동 종료
ALTER DATABASE ecommerce SET idle_in_transaction_session_timeout = '10min';
```

### 장애 대응: 프로세스가 너무 많을 때

```bash
# 1. 상황 파악
docker exec pg17-lab psql -U labuser -d ecommerce -c \
  "SELECT state, COUNT(*) FROM pg_stat_activity GROUP BY state;"

# 2. idle 세션이 많다면 → 애플리케이션 연결 풀 문제
# 3. active가 많다면 → 슬로우 쿼리 확인
docker exec pg17-lab psql -U labuser -d ecommerce -c \
  "SELECT pid, substring(query,1,80) FROM pg_stat_activity WHERE state = 'active' AND query_start < now() - interval '1 minute';"
```

### ✅ 직접 확인: pgbench 스트레스 테스트

컨테이너 셸에서:
```bash
# pgbench용 테이블 초기화
pgbench -i -s 10 -U labuser ecommerce

# 10개 클라이언트, 10초 실행
pgbench -c 10 -T 10 -U labuser ecommerce
```

실행 중에 다른 터미널에서:
```bash
# 프로세스 수 증가 확인
ps aux | grep "postgres:" | grep -v grep | wc -l
```

```sql
-- SQL로 동시 접속 수 확인
SELECT COUNT(*) FROM pg_stat_activity WHERE backend_type = 'client backend';
```

---

## 참고 링크

### 공식 문서 (PostgreSQL 17)

1. **Server Setup and Operation**
   https://www.postgresql.org/docs/17/runtime.html

2. **Internals - Overview of PostgreSQL Internals**
   https://www.postgresql.org/docs/17/overview.html

3. **Monitoring Database Activity**
   https://www.postgresql.org/docs/17/monitoring.html

### 추천 도서

- "PostgreSQL 14 Internals" by Egor Rogov
- "The Internals of PostgreSQL" by Hironobu Suzuki
  https://www.interdb.jp/pg/

### 도구

- **PgBouncer**: Connection pooler — https://www.pgbouncer.org/
- **pg_top**: 실시간 프로세스 모니터링 — https://pg_top.gitlab.io/

## 다이어그램 참조

```
diagrams/01-process-architecture.drawio
```

다이어그램 내용:
1. postmaster → 백엔드 fork 흐름
2. 백그라운드 워커 프로세스들의 역할
3. 공유 메모리 구조
4. 쿼리 처리 파이프라인 (Parser → Rewriter → Planner → Executor)
