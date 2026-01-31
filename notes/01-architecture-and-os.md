# PostgreSQL 아키텍처와 OS 프로세스 모델

## 한줄 요약

PostgreSQL은 클라이언트 요청마다 postmaster가 fork()로 독립적인 백엔드 프로세스를 생성하는 멀티프로세스 아키텍처를 사용하며, 공유 메모리와 IPC를 통해 프로세스 간 통신을 수행합니다.

## 왜 알아야 하는가

### 성능 문제 진단의 출발점

프로덕션 환경에서 갑자기 응답이 느려졌을 때, `ps aux | grep postgres`로 프로세스 목록을 확인하면 수백 개의 백엔드 프로세스가 보일 수 있습니다. 이것이 정상인지, 문제인지 판단하려면 PostgreSQL의 프로세스 모델을 이해해야 합니다.

### 리소스 설정의 근거

`shared_buffers` 설정값이 OS 공유 메모리 한계를 초과하면 PostgreSQL이 시작조차 되지 않습니다. `shmmax`, `shmall` 같은 OS 커널 파라미터와 PostgreSQL 설정의 관계를 알아야 적절히 튜닝할 수 있습니다.

### 멀티테넌시 환경 설계

이커머스 플랫폼에서 동시 접속자 1만 명을 처리해야 한다면, 각각에 백엔드 프로세스를 할당할 것인가? Connection pooling을 쓸 것인가? 아키텍처를 이해해야 올바른 설계가 가능합니다.

### 장애 격리와 안정성

한 쿼리가 메모리를 과도하게 사용해도 다른 세션은 영향을 받지 않습니다. 프로세스 기반 아키텍처가 주는 격리 효과를 이해하면 시스템의 안정성을 더 잘 보장할 수 있습니다.

## 핵심 개념

### 1. PostgreSQL 클라이언트 요청 처리 전체 흐름

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

#### 단계별 상세 설명

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

### 2. OS 관점: 프로세스 모델

#### postmaster의 역할

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

#### fork() 기반 프로세스 생성

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

#### 왜 쓰레드가 아닌 프로세스인가?

PostgreSQL이 처음 개발된 1990년대에는:
- 멀티스레딩이 OS마다 구현이 달랐음
- POSIX threads 표준이 불안정했음
- fork()가 더 안정적이고 이식성이 높았음

현재도 프로세스 모델을 유지하는 이유:
- **안정성**: 30년간 검증된 아키텍처
- **격리성**: 프로세스 격리가 주는 안전성
- **확장성**: 대부분 시나리오에서 충분한 성능
- **변경 비용**: 스레드 모델로 전환하려면 전체 재작성 필요

### 3. ps aux로 프로세스 확인하기

#### 실제 프로세스 목록 예시

```bash
$ ps aux | grep postgres
postgres  1234  0.0  0.5 123456 12345 ?  Ss   10:00   0:00 /usr/lib/postgresql/17/bin/postgres -D /var/lib/postgresql/17/main
postgres  1235  0.0  0.2  98765  9876 ?  Ss   10:00   0:00 postgres: checkpointer
postgres  1236  0.0  0.2  98765  9876 ?  Ss   10:00   0:00 postgres: background writer
postgres  1237  0.0  0.2  98765  9876 ?  Ss   10:00   0:00 postgres: walwriter
postgres  1238  0.0  0.3  99999  9999 ?  Ss   10:00   0:00 postgres: autovacuum launcher
postgres  1239  0.0  0.2  98765  9876 ?  Ss   10:00   0:00 postgres: logical replication launcher
postgres  5678  0.5  1.2 135000 13500 ?  Ss   11:30   0:15 postgres: ecommerce_user ecommerce_db 192.168.1.100(54321) idle
postgres  5679  2.1  3.5 245000 35000 ?  Rs   11:35   1:23 postgres: ecommerce_user ecommerce_db 192.168.1.101(54322) SELECT
```

#### 프로세스 유형 분석

**1. postmaster (PID 1234)**
- 가장 먼저 시작된 메인 프로세스
- 모든 다른 프로세스의 부모

**2. 백그라운드 워커 프로세스들**
- checkpointer
- background writer
- walwriter
- autovacuum launcher
- logical replication launcher

**3. 백엔드 프로세스 (PID 5678, 5679)**
- `ecommerce_user`: 접속한 데이터베이스 사용자
- `ecommerce_db`: 연결된 데이터베이스 이름
- `192.168.1.100(54321)`: 클라이언트 IP와 포트
- `idle` / `SELECT`: 현재 상태

### 4. Background Workers 상세 설명

#### checkpointer

**역할:**
- 주기적으로 더티 페이지(메모리에서 수정되었지만 디스크에 아직 안 쓴 페이지)를 디스크에 기록
- WAL과 데이터 파일 동기화

**설정:**
```sql
-- postgresql.conf
checkpoint_timeout = 5min           -- 체크포인트 간격
max_wal_size = 1GB                  -- WAL 크기 임계값
checkpoint_completion_target = 0.9  -- 체크포인트를 간격의 90%에 걸쳐 분산
```

**모니터링:**
```sql
-- PostgreSQL 17의 새로운 뷰
SELECT * FROM pg_stat_checkpointer;
```

#### background writer (bgwriter)

**역할:**
- checkpointer를 돕기 위해 지속적으로 더티 페이지를 디스크에 기록
- 체크포인트 시 부하를 줄임

**설정:**
```sql
bgwriter_delay = 200ms              -- 라운드 간 지연
bgwriter_lru_maxpages = 100         -- 라운드당 최대 페이지 수
bgwriter_lru_multiplier = 2.0       -- 다음 라운드 예측 계수
```

#### walwriter

**역할:**
- WAL 버퍼의 내용을 주기적으로 WAL 파일에 기록
- 트랜잭션 커밋 시 fsync 대기 시간 단축

**설정:**
```sql
wal_writer_delay = 200ms            -- 쓰기 간격
wal_writer_flush_after = 1MB        -- 누적 시 즉시 flush
```

#### autovacuum launcher / worker

**역할:**
- 데드 튜플 정리 (VACUUM)
- 통계 정보 갱신 (ANALYZE)
- 트랜잭션 ID wraparound 방지

**설정:**
```sql
autovacuum = on                                   -- 기본 활성화
autovacuum_max_workers = 3                        -- 동시 워커 수
autovacuum_naptime = 1min                         -- 실행 간격
autovacuum_vacuum_scale_factor = 0.2              -- 테이블 대비 dead tuple 비율
autovacuum_vacuum_insert_scale_factor = 0.2       -- v17: INSERT 기반 트리거
```

#### logical replication launcher

**역할:**
- 논리 복제 워커 관리
- 구독(subscription) 상태 모니터링

### 5. OS 관점: 공유 메모리

#### System V Shared Memory vs mmap

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

#### shared_buffers가 올라가는 구조

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

#### shmmax와 shmall 설정

**Linux에서 확인:**
```bash
# 최대 단일 공유 메모리 세그먼트 크기 (bytes)
$ cat /proc/sys/kernel/shmmax
18446744073692774400

# 시스템 전체 공유 메모리 페이지 수
$ cat /proc/sys/kernel/shmall
18446744073692774400

# 페이지 크기 확인
$ getconf PAGE_SIZE
4096
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

적용:
```bash
sudo sysctl -p
```

### 6. OS 관점: IPC (Inter-Process Communication)

#### 세마포어 (Semaphores)

PostgreSQL은 프로세스 간 동기화를 위해 세마포어를 사용합니다.

**System V 세마포어 확인:**
```bash
$ ipcs -s

------ Semaphore Arrays --------
key        semid      owner      perms      nsems
0x00052e2c 98304      postgres   600        17
```

**용도:**
- 공유 버퍼 락
- LWLock (Lightweight Lock)
- 트랜잭션 로깅

**관련 커널 파라미터:**
```bash
$ cat /proc/sys/kernel/sem
250     32000   32      128
# SEMMSL  SEMMNS  SEMOPM  SEMMNI
# (세마포어 세트당 최대 수) (시스템 전체 세마포어 수) (세마포어 작업당 최대 수) (최대 세마포어 세트 수)
```

#### 시그널 (Signals)

postmaster와 백엔드 간 통신에 시그널을 사용합니다.

**주요 시그널:**
- `SIGTERM`: 정상 종료 (smart shutdown)
- `SIGINT`: 빠른 종료 (fast shutdown)
- `SIGQUIT`: 즉시 종료 (immediate shutdown)
- `SIGHUP`: 설정 재로드
- `SIGUSR1`: 체크포인트 요청

**예시:**
```bash
# 설정 재로드 (postgresql.conf 변경 후)
pg_ctl reload -D /var/lib/postgresql/17/main

# 또는
kill -HUP $(head -1 /var/lib/postgresql/17/main/postmaster.pid)
```

### 7. 쿼리 처리 파이프라인 상세

#### Parser (구문 분석기)

**입력:** SQL 문자열
**출력:** Parse Tree (파싱 트리)

```sql
SELECT u.name, COUNT(o.id)
FROM users u
JOIN orders o ON u.id = o.user_id
WHERE o.created_at > '2024-01-01'
GROUP BY u.name;
```

**파싱 트리 구조 (단순화):**
```
SelectStmt
├─ targetList: [u.name, COUNT(o.id)]
├─ fromClause
│  ├─ RangeVar: users (alias: u)
│  └─ JoinExpr
│     ├─ left: orders (alias: o)
│     └─ condition: u.id = o.user_id
├─ whereClause: o.created_at > '2024-01-01'
└─ groupClause: [u.name]
```

**검증 사항:**
- 문법 오류
- 테이블/컬럼 존재 여부
- 타입 호환성
- 권한 확인

#### Rewriter (재작성기)

**역할:**
- 뷰를 실제 테이블 쿼리로 변환
- 규칙(RULE) 적용
- 파티션 프루닝 정보 추가

**예시: 뷰 확장**
```sql
-- 뷰 정의
CREATE VIEW active_users AS
SELECT * FROM users WHERE deleted_at IS NULL;

-- 쿼리
SELECT * FROM active_users WHERE email = 'test@example.com';

-- 재작성 후
SELECT * FROM users
WHERE deleted_at IS NULL AND email = 'test@example.com';
```

#### Planner (실행 계획기)

**입력:** 재작성된 쿼리 트리
**출력:** 실행 계획 (Plan Tree)

**고려 사항:**
1. **통계 정보**
   - 테이블 행 수 (pg_class.reltuples)
   - 컬럼 분포 (pg_stats)
   - 인덱스 선택도

2. **비용 계산**
   - seq_page_cost (순차 읽기)
   - random_page_cost (랜덤 읽기)
   - cpu_tuple_cost (튜플 처리)
   - cpu_operator_cost (연산자 비용)

3. **조인 전략**
   - Nested Loop: 작은 테이블 × 인덱스 조회
   - Hash Join: 중간 크기 테이블
   - Merge Join: 정렬된 데이터

**EXPLAIN으로 확인:**
```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.name, COUNT(o.id)
FROM users u
JOIN orders o ON u.id = o.user_id
WHERE o.created_at > '2024-01-01'
GROUP BY u.name;
```

#### Executor (실행기)

**역할:**
- 플랜 트리를 순회하며 실제 실행
- 각 노드는 iterator 패턴 (Init → Next → End)

**실행 모델:**
```
1. ExecInit: 리소스 할당, 인덱스 열기
2. ExecProcNode: 다음 튜플 가져오기 (재귀적 호출)
3. ExecEnd: 리소스 정리
```

**메모리 사용:**
- `work_mem`: 정렬, 해시 작업
- `temp_buffers`: 임시 테이블

## OS/파일시스템 관점

### 프로세스 메모리 레이아웃

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

**리눅스에서 확인:**
```bash
# 특정 백엔드 프로세스의 메모리 맵
cat /proc/[PID]/maps

# 예시 출력
7f8a4c000000-7f8a5c000000 rw-s 00000000 00:11 12345  /dev/shm/PostgreSQL.123456789
# ↑ 공유 메모리 영역
```

### CPU와 스케줄링

#### 컨텍스트 스위칭

프로세스 전환 시 커널이 수행하는 작업:
1. 현재 프로세스의 레지스터 상태 저장
2. 다음 프로세스의 상태 복원
3. 메모리 매핑 전환 (TLB flush)

**비용:**
- 스레드 전환: ~1-2 마이크로초
- 프로세스 전환: ~5-10 마이크로초

**확인 방법:**
```bash
# 컨텍스트 스위칭 횟수
vmstat 1

# 프로세스별 컨텍스트 스위칭
pidstat -w -p [PID] 1
```

#### CPU 친화성 (CPU Affinity)

특정 백엔드를 특정 CPU 코어에 고정:
```bash
# PostgreSQL 백엔드를 CPU 0-3에 고정
taskset -cp 0-3 [PID]
```

**사용 사례:**
- NUMA 시스템에서 메모리 지역성 향상
- 실시간 워크로드 격리

### 파일 디스크립터

각 백엔드는 다수의 파일 디스크립터를 사용합니다:

**확인:**
```bash
# 백엔드가 연 파일 목록
lsof -p [PID]

# 또는
ls -la /proc/[PID]/fd
```

**주요 FD:**
- 데이터 파일 (테이블, 인덱스)
- WAL 파일
- 소켓 (클라이언트 연결)
- 로그 파일

**한계 설정:**
```bash
# 프로세스당 최대 FD 수
ulimit -n

# 영구 설정 (/etc/security/limits.conf)
postgres soft nofile 65536
postgres hard nofile 65536
```

### 프로세스 우선순위

백그라운드 워커의 우선순위를 조정할 수 있습니다:

```bash
# checkpointer의 우선순위를 낮춤 (nice 값 증가)
renice +5 -p [CHECKPOINTER_PID]

# walwriter의 우선순위를 높임
renice -5 -p [WALWRITER_PID]
```

**주의:** 너무 공격적으로 조정하면 시스템 불안정 초래

## 실습 SQL

### 1. 현재 프로세스 정보 조회

```sql
-- 모든 백엔드 프로세스 목록
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    backend_start,
    state,
    state_change,
    query_start,
    query
FROM pg_stat_activity
ORDER BY backend_start;

-- 결과 예시:
--  pid  | usename  | application_name | client_addr |       backend_start       |  state  | query
-- ------+----------+------------------+-------------+---------------------------+---------+-------
--  1234 | postgres | psql             | 192.168.1.10| 2024-01-31 10:00:00+09    | active  | SELECT * FROM users;
--  1235 | webapp   | webapp-1         | 172.17.0.2  | 2024-01-31 10:05:00+09    | idle    |
```

### 2. 특정 쿼리 실행 중인 프로세스 찾기

```sql
-- 'orders' 테이블을 사용 중인 세션
SELECT
    pid,
    usename,
    state,
    wait_event_type,
    wait_event,
    query
FROM pg_stat_activity
WHERE query ILIKE '%orders%'
  AND state != 'idle';
```

### 3. 오래 실행 중인 쿼리 찾기

```sql
-- 5분 이상 실행 중인 쿼리
SELECT
    pid,
    now() - query_start AS duration,
    usename,
    query
FROM pg_stat_activity
WHERE state = 'active'
  AND query_start < now() - interval '5 minutes'
ORDER BY duration DESC;
```

### 4. 유휴 트랜잭션 찾기

```sql
-- idle in transaction 상태 (위험!)
SELECT
    pid,
    now() - state_change AS idle_duration,
    usename,
    query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND state_change < now() - interval '1 minute'
ORDER BY idle_duration DESC;

-- 이런 세션은 락을 잡고 있을 수 있어 위험
-- 필요시 종료:
-- SELECT pg_terminate_backend(pid);
```

### 5. 백그라운드 워커 모니터링

```sql
-- autovacuum 워커 확인
SELECT
    pid,
    query_start,
    state,
    query
FROM pg_stat_activity
WHERE backend_type = 'autovacuum worker';

-- checkpointer 통계 (PostgreSQL 17)
SELECT
    checkpoints_timed,      -- 스케줄된 체크포인트
    checkpoints_req,        -- 요청된 체크포인트
    checkpoint_write_time,  -- 쓰기 시간 (ms)
    checkpoint_sync_time,   -- fsync 시간 (ms)
    buffers_checkpoint,     -- 체크포인트가 쓴 버퍼 수
    buffers_clean,          -- bgwriter가 쓴 버퍼 수
    buffers_backend         -- 백엔드가 직접 쓴 버퍼 수
FROM pg_stat_checkpointer;
```

### 6. 프로세스 강제 종료

```sql
-- 우아한 종료 (쿼리 완료 대기)
SELECT pg_cancel_backend(1234);

-- 강제 종료 (즉시)
SELECT pg_terminate_backend(1234);

-- 특정 사용자의 모든 세션 종료
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = 'old_user' AND pid != pg_backend_pid();
```

### 7. 이커머스 시나리오: 동시성 확인

```sql
-- 현재 orders 테이블에 접근 중인 세션 수
SELECT COUNT(*)
FROM pg_stat_activity
WHERE query ILIKE '%orders%'
  AND state = 'active';

-- 결제 처리 중인 세션들
SELECT
    pid,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    substring(query, 1, 100) AS query_snippet
FROM pg_stat_activity
WHERE query ILIKE '%payments%INSERT%'
   OR query ILIKE '%orders%UPDATE%status%';
```

### 8. 락 대기 분석

```sql
-- 락을 대기 중인 프로세스와 락을 잡고 있는 프로세스
SELECT
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocked_activity.query AS blocked_statement,
    blocking_activity.query AS blocking_statement,
    blocked_activity.application_name AS blocked_app
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

### 9. 공유 메모리 사용량 확인

```sql
-- shared_buffers 사용 현황
SELECT
    setting::int * pg_size_bytes(unit) AS shared_buffers_bytes,
    pg_size_pretty(setting::int * pg_size_bytes(unit)) AS shared_buffers_size
FROM pg_settings
WHERE name = 'shared_buffers';

-- 버퍼 풀 히트율
SELECT
    sum(heap_blks_read) AS heap_read,
    sum(heap_blks_hit) AS heap_hit,
    sum(heap_blks_hit) / (sum(heap_blks_hit) + sum(heap_blks_read)) AS hit_ratio
FROM pg_statio_user_tables;
-- hit_ratio > 0.99가 이상적
```

### 10. 이커머스 실전 쿼리: 피크 타임 분석

```sql
-- 시간대별 동시 접속자 수 (event_logs 파티션 활용)
WITH active_sessions AS (
    SELECT
        date_trunc('hour', backend_start) AS hour,
        COUNT(*) AS session_count,
        COUNT(*) FILTER (WHERE state = 'active') AS active_count,
        COUNT(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_tx_count
    FROM pg_stat_activity
    WHERE backend_type = 'client backend'
    GROUP BY date_trunc('hour', backend_start)
)
SELECT
    hour,
    session_count,
    active_count,
    idle_in_tx_count,
    CASE
        WHEN session_count > 100 THEN 'HIGH'
        WHEN session_count > 50 THEN 'MEDIUM'
        ELSE 'LOW'
    END AS load_level
FROM active_sessions
ORDER BY hour DESC;
```

## 직접 확인해보기

### Docker 실습 환경 구성

```yaml
# docker-compose.yml
version: '3.8'
services:
  postgres:
    image: postgres:17
    container_name: pg17-architecture-lab
    environment:
      POSTGRES_PASSWORD: mysecretpassword
      POSTGRES_DB: ecommerce_db
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    command:
      - postgres
      - -c
      - shared_buffers=256MB
      - -c
      - max_connections=100
      - -c
      - log_statement=all
      - -c
      - log_line_prefix=%t [%p]: user=%u,db=%d,app=%a,client=%h

volumes:
  pgdata:
```

시작:
```bash
docker-compose up -d
docker exec -it pg17-architecture-lab bash
```

### 실습 1: 프로세스 목록 확인

컨테이너 안에서:
```bash
# PostgreSQL 프로세스들
ps aux | grep postgres

# 프로세스 트리
ps auxf | grep postgres

# 또는 pstree
apt-get update && apt-get install -y psmisc
pstree -p | grep postgres
```

**예상 출력:**
```
postgres     1  0.0  0.5 123456 12345 ?  Ss   10:00  0:00 postgres
postgres    10  0.0  0.2  98765  9876 ?  Ss   10:00  0:00  \_ postgres: checkpointer
postgres    11  0.0  0.2  98765  9876 ?  Ss   10:00  0:00  \_ postgres: background writer
postgres    12  0.0  0.2  98765  9876 ?  Ss   10:00  0:00  \_ postgres: walwriter
postgres    13  0.0  0.3  99999  9999 ?  Ss   10:00  0:00  \_ postgres: autovacuum launcher
postgres    14  0.0  0.2  98765  9876 ?  Ss   10:00  0:00  \_ postgres: logical replication launcher
```

### 실습 2: 공유 메모리 확인

```bash
# System V 공유 메모리 세그먼트
ipcs -m

# 세마포어
ipcs -s

# PostgreSQL이 사용 중인 공유 메모리 크기
ipcs -m | grep postgres

# 또는 /proc를 통해
cat /proc/$(pgrep -o postgres)/maps | grep /dev/shm
```

### 실습 3: 백엔드 프로세스 생성 관찰

**터미널 1 (모니터링):**
```bash
watch -n 1 'ps aux | grep postgres | grep -v grep'
```

**터미널 2 (클라이언트 연결):**
```bash
# 5개 연결 생성
for i in {1..5}; do
    psql -h localhost -U postgres -d ecommerce_db -c "SELECT pg_sleep(60);" &
done

# 프로세스 목록에 5개의 새 백엔드가 나타나는지 확인
```

**터미널 3 (SQL 모니터링):**
```sql
SELECT pid, state, query
FROM pg_stat_activity
WHERE query LIKE '%pg_sleep%';
```

### 실습 4: 프로세스 메모리 사용량 비교

```bash
# postmaster 메모리
PID=$(pgrep -o postgres)
cat /proc/$PID/status | grep -E 'VmSize|VmRSS|VmData'

# 백엔드 프로세스 메모리
BACKEND_PID=$(pgrep -P $(pgrep -o postgres) | head -1)
cat /proc/$BACKEND_PID/status | grep -E 'VmSize|VmRSS|VmData'

# 차이 확인
```

### 실습 5: 스트레스 테스트

pgbench로 부하 생성:
```bash
# 데이터베이스 초기화
pgbench -i -s 10 ecommerce_db

# 10개 클라이언트, 10초 실행
pgbench -c 10 -T 10 ecommerce_db

# 실행 중 다른 터미널에서:
ps aux | grep postgres | wc -l  # 프로세스 수 증가 확인
```

### 실습 6: 백그라운드 워커 작동 확인

```sql
-- autovacuum 활성화 확인
SHOW autovacuum;

-- 강제로 autovacuum 트리거
CREATE TABLE vacuum_test (id INT, data TEXT);
INSERT INTO vacuum_test SELECT i, repeat('x', 100) FROM generate_series(1, 10000) i;
DELETE FROM vacuum_test WHERE id % 2 = 0;

-- 잠시 후 pg_stat_activity 확인
SELECT pid, query
FROM pg_stat_activity
WHERE backend_type = 'autovacuum worker';
```

### 실습 7: 쿼리 파이프라인 추적

```sql
-- 실행 계획 확인 (Parser → Planner 결과)
EXPLAIN (VERBOSE, COSTS, BUFFERS)
SELECT u.email, COUNT(o.id) AS order_count
FROM users u
LEFT JOIN orders o ON u.id = o.user_id
WHERE u.created_at > CURRENT_DATE - INTERVAL '30 days'
GROUP BY u.email
HAVING COUNT(o.id) > 5
ORDER BY order_count DESC
LIMIT 10;

-- 실제 실행 (Executor)
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.email, COUNT(o.id) AS order_count
FROM users u
LEFT JOIN orders o ON u.id = o.user_id
WHERE u.created_at > CURRENT_DATE - INTERVAL '30 days'
GROUP BY u.email
HAVING COUNT(o.id) > 5
ORDER BY order_count DESC
LIMIT 10;
```

### 실습 8: 프로세스 간 격리 테스트

**세션 1:**
```sql
BEGIN;
SELECT * FROM users WHERE id = 1 FOR UPDATE;
-- 커밋하지 않고 대기
```

**세션 2:**
```sql
-- 같은 행 업데이트 시도 (블로킹됨)
UPDATE users SET email = 'new@example.com' WHERE id = 1;
```

**세션 3 (모니터링):**
```sql
-- 락 대기 상황 확인
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.query AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_locks blocked_locks ON blocked.pid = blocked_locks.pid
JOIN pg_locks blocking_locks
    ON blocking_locks.relation = blocked_locks.relation
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_stat_activity blocking ON blocking.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;
```

## 실무 팁

### 1. Connection Pooling은 필수

**문제:**
- 웹 애플리케이션에서 각 요청마다 새 연결 생성
- fork() 오버헤드 + 인증 오버헤드
- 수천 개 동시 연결 시 메모리 고갈

**해결:**
```javascript
// Node.js에서 pg-pool 사용
const { Pool } = require('pg');
const pool = new Pool({
  host: 'localhost',
  database: 'ecommerce_db',
  max: 20,                    // 최대 20개 연결 유지
  idleTimeoutMillis: 30000,   // 30초 유휴 시 반환
  connectionTimeoutMillis: 2000,
});

// 연결 재사용
const result = await pool.query('SELECT * FROM users WHERE id = $1', [userId]);
```

또는 PgBouncer 같은 외부 풀러 사용:
```ini
# pgbouncer.ini
[databases]
ecommerce_db = host=localhost port=5432 dbname=ecommerce_db

[pgbouncer]
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
```

### 2. max_connections 설정 전략

**공식:**
```
max_connections = (available_ram - shared_buffers - OS) / work_mem
```

**예시:**
- 시스템 메모리: 16GB
- shared_buffers: 4GB
- OS + 기타: 2GB
- work_mem: 4MB

```
max_connections ≈ (16GB - 4GB - 2GB) / 4MB = 2,560
```

하지만 실전에서는 100-200이 적당:
```sql
-- postgresql.conf
max_connections = 200
shared_buffers = 4GB
work_mem = 4MB
```

### 3. idle in transaction 방지

애플리케이션에서 반드시 트랜잭션을 빨리 닫아야 합니다:

**나쁜 예:**
```javascript
const client = await pool.connect();
try {
  await client.query('BEGIN');
  const result = await client.query('SELECT * FROM users');
  // 여기서 비즈니스 로직 수행 (오래 걸림)
  await processUsers(result.rows);  // 30초 소요
  await client.query('COMMIT');
} finally {
  client.release();
}
```

**좋은 예:**
```javascript
const client = await pool.connect();
try {
  await client.query('BEGIN');
  const result = await client.query('SELECT * FROM users FOR UPDATE');
  await client.query('UPDATE users SET ... WHERE id = $1', [id]);
  await client.query('COMMIT');
} finally {
  client.release();
}
// 트랜잭션 밖에서 비즈니스 로직 수행
await processUsers(result.rows);
```

PostgreSQL에서 강제 종료 설정:
```sql
-- 10분 이상 idle in transaction 상태면 자동 종료
ALTER DATABASE ecommerce_db SET idle_in_transaction_session_timeout = '10min';
```

### 4. 백그라운드 워커 튜닝

**checkpointer:**
```sql
-- 체크포인트를 더 자주, 하지만 부드럽게
checkpoint_timeout = 5min
checkpoint_completion_target = 0.9  -- 4.5분에 걸쳐 분산
max_wal_size = 2GB
```

**autovacuum:**
```sql
-- 테이블이 많은 경우 워커 늘리기
autovacuum_max_workers = 5

-- 특정 핫 테이블은 더 자주 vacuum
ALTER TABLE orders SET (autovacuum_vacuum_scale_factor = 0.05);

-- 대용량 테이블은 vacuum 비용 낮춤 (더 빠르게)
ALTER TABLE event_logs SET (autovacuum_vacuum_cost_delay = 10);
```

### 5. 모니터링 쿼리를 저장해두기

```sql
-- 유용한 모니터링 뷰 생성
CREATE VIEW v_active_queries AS
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    now() - query_start AS duration,
    state,
    wait_event_type,
    wait_event,
    substring(query, 1, 200) AS query_snippet
FROM pg_stat_activity
WHERE state != 'idle'
  AND pid != pg_backend_pid()
ORDER BY duration DESC;

-- 사용
SELECT * FROM v_active_queries;
```

### 6. 장애 대응: 프로세스가 너무 많을 때

```bash
# 1. 상황 파악
psql -c "SELECT state, COUNT(*) FROM pg_stat_activity GROUP BY state;"

# 2. idle 세션이 많다면 애플리케이션 연결 풀 문제
# 3. active가 많다면 슬로우 쿼리 확인
psql -c "SELECT pid, query FROM pg_stat_activity WHERE state = 'active' AND query_start < now() - interval '1 minute';"

# 4. 필요시 특정 세션 종료
psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle' AND state_change < now() - interval '1 hour';"
```

### 7. 개발 환경 vs 프로덕션 설정

**개발 환경:**
```sql
max_connections = 20
shared_buffers = 128MB
work_mem = 4MB
```

**프로덕션 환경:**
```sql
max_connections = 200
shared_buffers = 4GB
work_mem = 16MB
maintenance_work_mem = 512MB
```

### 8. 프로세스 모니터링 자동화

```bash
#!/bin/bash
# monitor_postgres.sh

THRESHOLD=80

CONN_COUNT=$(psql -t -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend';")

if [ $CONN_COUNT -gt $THRESHOLD ]; then
    echo "Alert: Too many connections ($CONN_COUNT)"
    psql -c "SELECT state, count(*) FROM pg_stat_activity GROUP BY state;"
    # Slack/이메일 알림 발송
fi
```

crontab:
```
*/5 * * * * /usr/local/bin/monitor_postgres.sh
```

## 참고 링크

### 공식 문서 (PostgreSQL 17)

1. **Server Setup and Operation**
   https://www.postgresql.org/docs/17/runtime.html
   - 18.3 Starting the Database Server
   - 18.4 Managing Kernel Resources

2. **Internals - Overview of PostgreSQL Internals**
   https://www.postgresql.org/docs/17/overview.html
   - Chapter 52: Query Processing
   - Chapter 53: System Catalogs

3. **Database Physical Storage**
   https://www.postgresql.org/docs/17/storage.html
   - Chapter 73: Database File Layout
   - Chapter 74: System Catalog Declarations and Initial Contents

4. **Monitoring Database Activity**
   https://www.postgresql.org/docs/17/monitoring.html
   - 28.2 The Cumulative Statistics System
   - pg_stat_activity 뷰

5. **PostgreSQL 17 Release Notes**
   https://www.postgresql.org/docs/17/release-17.html
   - pg_stat_checkpointer 뷰 추가
   - autovacuum_vacuum_insert_scale_factor 개선

### 추천 도서

- "PostgreSQL 14 Internals" by Egor Rogov
  (아키텍처와 내부 동작 상세 설명)

- "The Internals of PostgreSQL" by Hironobu Suzuki
  https://www.interdb.jp/pg/

### 도구

- **pgAdmin**: GUI 모니터링
  https://www.pgadmin.org/

- **pg_top**: 실시간 프로세스 모니터링
  https://pg_top.gitlab.io/

- **PgBouncer**: Connection pooler
  https://www.pgbouncer.org/

## 다이어그램 참조

본 노트에서 언급한 다이어그램은 다음 위치에 있습니다:

```
diagrams/01-process-architecture.drawio
```

다이어그램 내용:
1. postmaster → 백엔드 fork 흐름
2. 백그라운드 워커 프로세스들의 역할
3. 공유 메모리 구조
4. 쿼리 처리 파이프라인 (Parser → Rewriter → Planner → Executor)

Draw.io에서 열어 편집 가능합니다.

## 마무리

PostgreSQL의 프로세스 기반 아키텍처는 안정성과 격리성을 제공하지만, 제대로 이해하지 못하면 리소스 낭비나 성능 문제로 이어질 수 있습니다.

**핵심 포인트:**
1. **각 연결 = 새 프로세스** → Connection pooling 필수
2. **공유 메모리는 OS 한계 내에서** → shmmax/shmall 설정
3. **백그라운드 워커 튜닝** → autovacuum, checkpoint 설정
4. **pg_stat_activity로 상시 모니터링** → 문제 조기 발견

다음 노트에서는 PostgreSQL의 스토리지와 파일시스템을 OS 관점에서 깊이 살펴보겠습니다.
