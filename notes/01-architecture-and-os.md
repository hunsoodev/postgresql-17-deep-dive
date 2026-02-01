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

### checkpointer

**역할:**
- 주기적으로 더티 페이지(메모리에서 수정되었지만 디스크에 아직 안 쓴 페이지)를 디스크에 기록
- WAL과 데이터 파일 동기화

**현재 실습 환경 설정** (`docker/postgresql.conf`):
```
checkpoint_timeout = 5min
max_wal_size = 1GB
checkpoint_completion_target = 0.9   -- 체크포인트를 간격의 90%에 걸쳐 분산
```

### background writer (bgwriter)

**역할:**
- checkpointer를 돕기 위해 지속적으로 더티 페이지를 디스크에 기록
- 체크포인트 시 부하를 줄임

### walwriter

**역할:**
- WAL 버퍼의 내용을 주기적으로 WAL 파일에 기록
- 트랜잭션 커밋 시 fsync 대기 시간 단축

### autovacuum launcher / worker

**역할:**
- 데드 튜플 정리 (VACUUM)
- 통계 정보 갱신 (ANALYZE)
- 트랜잭션 ID wraparound 방지

**현재 실습 환경 설정** (`docker/postgresql.conf`):
```
autovacuum = on
autovacuum_max_workers = 3
autovacuum_vacuum_scale_factor = 0.2
```

### logical replication launcher

**역할:**
- 논리 복제 워커 관리
- 구독(subscription) 상태 모니터링

### ✅ 직접 확인: 백그라운드 워커 모니터링

```sql
-- checkpointer 통계 (PostgreSQL 17)
SELECT
    num_timed AS timed_checkpoints,
    num_requested AS requested_checkpoints,
    write_time,
    sync_time,
    buffers_written
FROM pg_stat_checkpointer;

-- bgwriter 통계
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

PostgreSQL은 프로세스 간 동기화를 위해 세마포어를 사용합니다.

**용도:**
- 공유 버퍼 락
- LWLock (Lightweight Lock)
- 트랜잭션 로깅

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
