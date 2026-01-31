# WAL(Write-Ahead Log)과 신뢰성

## 한줄 요약

WAL은 데이터 변경 사항을 먼저 순차적으로 로그 파일에 기록한 후 실제 데이터 파일을 갱신하는 메커니즘으로, 시스템 크래시 시에도 데이터 일관성과 내구성을 보장합니다.

## 왜 알아야 하는가

### 데이터 손실 방지의 핵심

이커머스 플랫폼에서 사용자가 결제를 완료한 직후 서버가 다운된다면? WAL이 제대로 설정되어 있다면 재시작 후 자동으로 복구되어 주문 데이터가 보존됩니다. WAL의 동작 원리를 모르면 이런 상황에 대처할 수 없습니다.

### 복제와 백업의 기반

PostgreSQL의 스트리밍 복제, PITR(Point-In-Time Recovery), 논리 복제는 모두 WAL을 기반으로 합니다. WAL을 이해해야 복제 지연, WAL 폭증, 복구 실패 등의 문제를 해결할 수 있습니다.

### 성능 튜닝의 핵심 포인트

"트랜잭션이 왜 이렇게 느린가?"의 답은 종종 WAL fsync 대기입니다. `checkpoint_timeout`, `max_wal_size`, `wal_buffers` 등의 설정을 이해하면 쓰기 성능을 크게 향상시킬 수 있습니다.

### 디스크 공간 관리

WAL 파일이 무한정 쌓여 디스크를 가득 채우는 사고가 종종 발생합니다. WAL 아카이빙, 복제 슬롯, checkpoint 메커니즘을 이해하면 이런 문제를 예방할 수 있습니다.

## 핵심 개념

### 1. WAL이란? - 비유로 이해하기

#### 일상 비유: 메모장과 정리

**상황:**
당신은 여러 책에서 중요한 내용을 정리하는 중입니다.

**방법 1: 바로 정리 (WAL 없음)**
- 중요한 내용을 발견하면 즉시 해당 책의 페이지를 찾아가서 형광펜 칠하기
- 여러 책을 왔다갔다 (랜덤 액세스)
- 작업 중 갑자기 중단되면 어디까지 했는지 모름

**방법 2: 메모장 먼저 (WAL 사용)**
- 중요한 내용을 모두 메모장에 순서대로 적기 (순차 쓰기)
- 나중에 시간 날 때 메모장을 보고 책에 반영 (체크포인트)
- 작업 중 중단되어도 메모장만 보면 어디서부터 다시 시작할지 알 수 있음

PostgreSQL의 WAL이 바로 이 "메모장"입니다.

#### 기술적 정의

**Write-Ahead Log:**
- 데이터 파일을 변경하기 **전에** 변경 내역을 로그에 먼저 기록
- 로그는 순차적으로 append-only로 기록 (빠름)
- 크래시 발생 시 로그를 재생(replay)하여 복구

**WAL의 핵심 원칙:**
1. 데이터 페이지를 디스크에 쓰기 **전에** WAL 레코드를 먼저 써야 함
2. 트랜잭션 커밋 시 해당 WAL 레코드가 디스크에 fsync되어야 함
3. WAL 레코드만 있으면 언제든 데이터 페이지를 재구성 가능

### 2. OS 관점: 순차 쓰기 vs 랜덤 쓰기

#### 디스크 I/O 특성

**HDD (Hard Disk Drive):**
```
순차 쓰기: ~200 MB/s
랜덤 쓰기: ~2 MB/s  (100배 차이!)

이유: 물리적인 헤드 이동 (seek time) + 회전 대기 (rotational latency)
```

**SSD (Solid State Drive):**
```
순차 쓰기: ~3000 MB/s
랜덤 쓰기: ~500 MB/s  (6배 차이)

이유: 블록 소거/재작성, Write Amplification
```

**WAL이 빠른 이유:**
- WAL은 파일 끝에 순차적으로 append만 함
- 데이터 파일은 여러 곳을 랜덤 업데이트
- 순차 쓰기 >> 랜덤 쓰기 (특히 HDD)

#### Write-Back Cache와 WAL fsync

**OS 쓰기 과정:**
```
애플리케이션
    ↓ write()
커널 page cache (메모리)
    ↓ (비동기)
디스크 write cache (휘발성!)
    ↓ (비동기)
디스크 플래터/셀 (영구 저장)
```

**문제:**
- `write()` 호출 후 바로 반환 (실제로는 cache에만)
- 정전 시 cache 내용 손실

**해결: fsync()**
```c
write(fd, data, size);
fsync(fd);  // 커널 cache → 디스크까지 강제로 쓰기
```

**PostgreSQL의 사용:**
```
트랜잭션 커밋 시:
1. WAL 버퍼 → WAL 파일에 write()
2. fsync(WAL 파일)  ← 여기서 대기
3. 클라이언트에 커밋 완료 응답
```

**fsync 비용:**
- HDD: ~10ms (회전 속도 제약)
- SSD: ~0.1ms (훨씬 빠름)
- PostgreSQL 커밋 성능의 주요 병목

**최적화: Group Commit**
- 여러 트랜잭션의 WAL을 모아서 한 번에 fsync
- `commit_delay` 설정으로 조절

### 3. WAL 동작 과정 상세

#### 전체 흐름

```
┌──────────────────────────────────────────────────────────────┐
│  1. 트랜잭션 시작                                             │
│     BEGIN;                                                   │
│     UPDATE users SET balance = balance + 100 WHERE id = 1;   │
│     COMMIT;                                                  │
└──────────────────────────────────────────────────────────────┘
                          ↓
┌──────────────────────────────────────────────────────────────┐
│  2. 실행 엔진                                                 │
│     - shared_buffers에서 페이지 읽기                          │
│     - 페이지 수정 (balance 값 변경)                           │
│     - 페이지를 "더티(dirty)" 상태로 표시                       │
└──────────────────────────────────────────────────────────────┘
                          ↓
┌──────────────────────────────────────────────────────────────┐
│  3. WAL 레코드 생성                                           │
│     - 변경 내역을 WAL 레코드로 직렬화                          │
│     - WAL 버퍼에 추가                                         │
│     - XLogInsert() 함수 호출                                  │
└──────────────────────────────────────────────────────────────┘
                          ↓
┌──────────────────────────────────────────────────────────────┐
│  4. 커밋 시 WAL 쓰기                                          │
│     - WAL 버퍼 → pg_wal/000000010000000000000001 파일에 write │
│     - fsync(WAL 파일)  ← 디스크까지 확실히 쓰기               │
│     - LSN (Log Sequence Number) 증가                          │
└──────────────────────────────────────────────────────────────┘
                          ↓
┌──────────────────────────────────────────────────────────────┐
│  5. 데이터 파일 쓰기 (나중에)                                  │
│     - 백그라운드 작업 (bgwriter, checkpointer)                │
│     - 더티 페이지를 데이터 파일에 쓰기                         │
│     - 체크포인트 시점에 대량으로 수행                          │
└──────────────────────────────────────────────────────────────┘
                          ↓
┌──────────────────────────────────────────────────────────────┐
│  6. 체크포인트 완료                                           │
│     - 특정 LSN 이전의 모든 더티 페이지가 디스크에 기록됨       │
│     - 해당 LSN 이전의 WAL은 복구 시 불필요                    │
│     - WAL 파일 재활용 또는 아카이빙                           │
└──────────────────────────────────────────────────────────────┘
```

#### LSN (Log Sequence Number)

**LSN:**
- WAL 레코드의 고유 위치를 나타내는 64비트 숫자
- 형식: `segno/offset` (예: `5/A1B2C3D4`)

**구조:**
```
LSN: 0x5A1B2C3D4
     ↓
세그먼트: 5 (파일명: 000000010000000000000005)
오프셋: A1B2C3D4 (파일 내 위치)
```

**주요 LSN:**
```sql
-- 현재 WAL 쓰기 위치
SELECT pg_current_wal_lsn();
--  5/A1B2C3D4

-- 마지막 체크포인트 LSN
SELECT checkpoint_lsn FROM pg_control_checkpoint();
--  5/90000000

-- 특정 페이지의 LSN (마지막으로 변경된 WAL 위치)
SELECT lsn FROM page_header(get_raw_page('users', 0));
--  5/A1000000
```

**LSN으로 복제 지연 측정:**
```sql
-- Primary 서버
SELECT pg_current_wal_lsn();
--  10/AB000000

-- Replica 서버
SELECT pg_last_wal_replay_lsn();
--  10/AA000000

-- 지연: AB000000 - AA000000 = ~16MB
```

### 4. Checkpoint: 언제, 왜 발생하는가

#### Checkpoint의 역할

**Checkpoint:**
- 특정 시점까지의 모든 더티 페이지를 디스크에 쓰기
- "여기까지는 데이터 파일이 WAL과 동기화되었다"는 표시

**목적:**
1. **복구 시간 단축**: 마지막 체크포인트부터만 WAL 재생하면 됨
2. **WAL 공간 관리**: 오래된 WAL 파일 재활용
3. **데이터 무결성**: 메모리와 디스크 동기화

#### Checkpoint 발생 조건

**1. 시간 기반 (checkpoint_timeout):**
```sql
-- postgresql.conf
checkpoint_timeout = 5min  -- 기본값

-- 5분마다 자동 체크포인트
```

**2. WAL 크기 기반 (max_wal_size):**
```sql
max_wal_size = 1GB  -- 기본값

-- WAL 파일 크기가 1GB 초과 시 체크포인트
```

**3. 수동 트리거:**
```sql
CHECKPOINT;  -- 즉시 체크포인트 (주의: 시스템 부하)
```

**4. 셧다운 시:**
- PostgreSQL 정상 종료 시 자동으로 체크포인트
- "clean shutdown" 보장

**5. 특정 작업 후:**
- `CREATE DATABASE`
- `pg_basebackup` 시작 시

#### Checkpoint 과정

```
1. 체크포인트 시작 결정 (checkpointer 프로세스)
   ↓
2. 현재 WAL 위치(LSN)를 체크포인트 LSN으로 기록
   ↓
3. shared_buffers의 모든 더티 페이지를 스캔
   ↓
4. 더티 페이지를 디스크에 쓰기 (점진적으로)
   - checkpoint_completion_target에 따라 분산
   - 예: checkpoint_timeout=5min, completion_target=0.9
     → 4.5분에 걸쳐 쓰기
   ↓
5. 모든 더티 페이지 쓰기 완료 시 fsync
   ↓
6. pg_control 파일에 체크포인트 정보 기록
   ↓
7. 오래된 WAL 파일 재활용 또는 삭제
```

#### 체크포인트 설정 튜닝

**기본 설정 (보수적):**
```sql
checkpoint_timeout = 5min
max_wal_size = 1GB
min_wal_size = 80MB
checkpoint_completion_target = 0.9
```

**쓰기 부하가 높은 시스템:**
```sql
checkpoint_timeout = 15min      -- 더 길게
max_wal_size = 4GB              -- 더 크게
checkpoint_completion_target = 0.9  -- 유지
```

**효과:**
- 체크포인트 빈도 감소 → I/O 스파이크 완화
- 대신 WAL 공간 증가 + 복구 시간 증가

**복구 시간 우선:**
```sql
checkpoint_timeout = 3min
max_wal_size = 512MB
```

**트레이드오프:**
- 빈번한 체크포인트: 복구 빠름, 실시간 성능 저하
- 드문 체크포인트: 실시간 성능 좋음, 복구 느림

### 5. Full Page Writes와 Torn Page 문제

#### Torn Page 문제

**상황:**
- PostgreSQL은 8KB 페이지 단위로 쓰기
- OS/디스크는 보통 512B 또는 4KB 섹터 단위
- 8KB 쓰기 = 여러 번의 섹터 쓰기

**문제 시나리오:**
```
1. PostgreSQL이 8KB 페이지를 쓰기 시작
2. 첫 4KB는 성공
3. 정전 발생!
4. 나머지 4KB는 실패
→ 페이지가 반쪽만 쓰인 상태 ("Torn Page")
```

**결과:**
- 페이지 내용이 일관성 없는 상태
- 체크섬 오류
- 데이터 손상

#### Full Page Writes 해결책

**원리:**
- 체크포인트 이후 처음으로 변경되는 페이지는 **전체 페이지**를 WAL에 기록
- 이후 같은 페이지 변경은 delta(변경 내역)만 기록

**예시:**
```
Checkpoint 완료 (LSN: 1/00000000)
↓
users 테이블의 페이지 10 변경
→ WAL에 전체 8KB 페이지 이미지 기록 (FPW)
↓
같은 페이지 10을 또 변경
→ WAL에 delta만 기록 (작음)
↓
다음 Checkpoint
↓
페이지 10 변경
→ WAL에 다시 전체 페이지 기록 (FPW)
```

**설정:**
```sql
-- postgresql.conf
full_page_writes = on  -- 기본값, 반드시 켜야 함!

-- 테스트 환경에서만 off (위험)
-- full_page_writes = off
```

**FPW의 영향:**
- WAL 크기 증가 (체크포인트 직후 급증)
- 쓰기 성능 저하 (8KB를 WAL에 기록)
- 하지만 데이터 무결성을 위해 필수

**WAL 압축으로 완화:**
```sql
wal_compression = on  -- PostgreSQL 9.5+

-- FPW 페이지를 압축하여 WAL에 기록
-- 압축률: 보통 50-70%
-- CPU 사용 증가하지만, I/O 감소로 전체적으로 이득
```

### 6. WAL 레벨

PostgreSQL은 3가지 WAL 레벨을 제공합니다.

#### minimal (PostgreSQL 17에서 deprecated)

```sql
wal_level = minimal
```

**특징:**
- 최소한의 WAL 기록
- 크래시 복구만 가능
- 복제, PITR 불가

**사용 불가:**
- PostgreSQL 17에서는 사용 금지
- replica 이상만 허용

#### replica (기본값)

```sql
wal_level = replica
```

**특징:**
- 물리 복제에 필요한 정보 기록
- 스트리밍 복제 가능
- PITR(Point-In-Time Recovery) 가능

**기록 내용:**
- 모든 데이터 변경
- 페이지 이미지 (FPW)
- 트랜잭션 상태

**사용 사례:**
- Primary-Standby 복제
- 연속 아카이빙

#### logical

```sql
wal_level = logical
```

**특징:**
- 논리 복제에 필요한 추가 정보 기록
- 행 단위 변경 정보 (OLD/NEW values)

**기록 내용:**
- replica 레벨의 모든 정보
- + 논리 디코딩에 필요한 메타데이터

**사용 사례:**
- 논리 복제 (다른 PostgreSQL 버전으로)
- 외부 시스템 연동 (Kafka, Elasticsearch)
- CDC (Change Data Capture)

**오버헤드:**
- replica보다 약간 더 많은 WAL 생성
- 보통 5-10% 증가

### 7. WAL 파일 구조

#### 파일 위치와 명명 규칙

**위치:**
```
$PGDATA/pg_wal/
```

**파일명 형식:**
```
000000010000000000000001
│      ││              │
│      ││              └─ Segment number (32비트)
│      │└─ Timeline ID 상위 32비트
│      └─ Timeline ID 하위 32비트 (보통 0)
└─ Timeline ID (8비트)

실제로는:
TTTTTTTTXXXXXXXXYYYYYYYY
│      │       │
│      │       └─ Segment number
│      └─ WAL 파일 그룹
└─ Timeline
```

**타임라인:**
- 복구 후 새로운 히스토리 시작 시 증가
- 예: 0x00000001 → 0x00000002

**세그먼트 크기:**
- 기본 16MB (컴파일 타임 설정 가능)
- `wal_segment_size` 확인:
```sql
SHOW wal_segment_size;
-- 16MB
```

#### 파일 목록 예시

```bash
$ ls -lh $PGDATA/pg_wal/

total 256M
-rw------- 1 postgres postgres 16M Jan 31 10:00 000000010000000000000001
-rw------- 1 postgres postgres 16M Jan 31 10:05 000000010000000000000002
-rw------- 1 postgres postgres 16M Jan 31 10:10 000000010000000000000003
-rw------- 1 postgres postgres 16M Jan 31 10:15 000000010000000000000004
-rw------- 1 postgres postgres 16M Jan 31 10:20 000000010000000000000005
-rw------- 1 postgres postgres 16M Jan 31 10:25 000000010000000000000006  ← 현재 쓰기 중
drwx------ 2 postgres postgres 4.0K Jan 31 09:00 archive_status/
```

**archive_status/ 디렉토리:**
- `.ready` 파일: 아카이빙 대기 중
- `.done` 파일: 아카이빙 완료

```bash
$ ls -la $PGDATA/pg_wal/archive_status/

000000010000000000000001.done
000000010000000000000002.done
000000010000000000000003.ready  ← 아카이빙 대기
```

#### LSN과 파일 오프셋 매핑

**LSN 예시: `5/A1B2C3D4`**

**분해:**
```
5 / A1B2C3D4
│   │
│   └─ 오프셋: 0xA1B2C3D4 = 2,713,879,508 bytes
└─ 논리적 세그먼트: 5
```

**파일명 계산:**
```
Segment = 5
File: 000000010000000000000005

Offset in file = 0xA1B2C3D4 % 16MB
                = 2,713,879,508 % 16,777,216
                = 약 10.5MB 위치
```

#### WAL 레코드 구조

```
┌─────────────────────────────────────────┐
│  WAL Record Header                      │
│  - xl_tot_len: 레코드 총 길이            │
│  - xl_xid: 트랜잭션 ID                   │
│  - xl_prev: 이전 레코드 LSN              │
│  - xl_info: 레코드 타입 정보             │
│  - xl_rmid: Resource Manager ID          │
│  - xl_crc: CRC32 체크섬                  │
├─────────────────────────────────────────┤
│  Main Data (변경 내역)                   │
│  예: Heap Insert, Update, Delete         │
├─────────────────────────────────────────┤
│  Block References (어느 페이지 변경?)    │
│  - relation oid                          │
│  - block number                          │
│  - FPW 이미지 (필요시)                   │
└─────────────────────────────────────────┘
```

**Resource Manager (RM):**
- Heap: 테이블 데이터 변경
- Btree: B-tree 인덱스 변경
- Hash: Hash 인덱스 변경
- Xlog: WAL 자체 관리 (체크포인트 등)
- Transaction: 커밋/어보트
- 등등...

### 8. pg_stat_checkpointer (PostgreSQL 17)

PostgreSQL 17에서 새로 추가된 뷰입니다.

#### 기존 문제 (PostgreSQL 16 이하)

```sql
-- 예전에는 pg_stat_bgwriter에 체크포인트 통계 포함
SELECT * FROM pg_stat_bgwriter;

-- checkpointer와 bgwriter 통계가 섞여있어 혼란
```

#### PostgreSQL 17 개선

**분리된 뷰:**
```sql
-- checkpointer 전용
SELECT * FROM pg_stat_checkpointer;

-- bgwriter 전용
SELECT * FROM pg_stat_bgwriter;
```

#### pg_stat_checkpointer 컬럼

```sql
SELECT * FROM pg_stat_checkpointer;

              컬럼               |    타입     | 설명
---------------------------------+-------------+------------------------------------------
 num_timed                       | bigint      | 시간 기반 체크포인트 수
 num_requested                   | bigint      | 요청된 체크포인트 수 (max_wal_size 초과 등)
 restartpoints_timed             | bigint      | 복제 서버의 시간 기반 재시작 포인트
 restartpoints_req               | bigint      | 복제 서버의 요청 재시작 포인트
 restartpoints_done              | bigint      | 완료된 재시작 포인트
 write_time                      | double      | 쓰기에 소요된 시간 (ms)
 sync_time                       | double      | fsync에 소요된 시간 (ms)
 buffers_written                 | bigint      | 체크포인트가 쓴 버퍼 수
 stats_reset                     | timestamptz | 통계 리셋 시간
```

**분석 예시:**
```sql
SELECT
    num_timed,
    num_requested,
    buffers_written,
    round(write_time::numeric, 2) AS write_time_ms,
    round(sync_time::numeric, 2) AS sync_time_ms,
    round((write_time + sync_time) / (num_timed + num_requested), 2) AS avg_checkpoint_time_ms
FROM pg_stat_checkpointer;

 num_timed | num_requested | buffers_written | write_time_ms | sync_time_ms | avg_checkpoint_time_ms
-----------+---------------+-----------------+---------------+--------------+------------------------
       100 |            10 |        5000000  |      45000.00 |     15000.00 |                  545.45

-- 평균 체크포인트 시간: 545ms
-- num_requested > 0 → max_wal_size 증가 고려
```

**알람 기준:**
```sql
-- 요청 체크포인트가 너무 많으면 경고
SELECT
    CASE
        WHEN num_requested::float / NULLIF(num_timed + num_requested, 0) > 0.3
        THEN 'WARNING: Too many requested checkpoints! Increase max_wal_size.'
        ELSE 'OK'
    END AS checkpoint_health
FROM pg_stat_checkpointer;
```

## OS/파일시스템 관점

### WAL 쓰기와 커널 I/O 스택

**쓰기 경로:**
```
PostgreSQL walwriter
         ↓ write()
    Page Cache (커널)
         ↓
    I/O Scheduler (CFQ, Deadline, noop)
         ↓
    Block Layer
         ↓
    Device Driver
         ↓
    Disk Controller (RAID)
         ↓
    Disk Write Cache (휘발성!)
         ↓ fsync()
    Physical Media (영구 저장)
```

**각 단계의 지연:**
- write() 호출: ~1 마이크로초 (메모리 복사)
- Page cache → Disk: 비동기 (수 밀리초)
- fsync() 대기: ~0.1-10ms (디스크 종류에 따라)

### Disk Write Cache

**문제:**
- 디스크는 자체 휘발성 캐시를 가짐 (수백 MB)
- fsync()가 완료되어도 실제로는 캐시에만 있을 수 있음
- 정전 시 손실

**해결:**
```bash
# 디스크 write cache 상태 확인
hdparm -W /dev/sda

write-caching =  1 (on)  # 위험!

# 비활성화
hdparm -W0 /dev/sda

# 또는 디스크가 배터리 백업(BBU)을 지원한다면 안전
# RAID 컨트롤러의 BBU(Battery Backup Unit)
```

**RAID 컨트롤러:**
- BBU가 있는 RAID 컨트롤러는 안전
- 정전 시 캐시 내용을 배터리로 보호
- fsync()를 빠르게 완료 (10x 이상 빠름)

### I/O Scheduler

**리눅스 I/O 스케줄러 종류:**

**1. noop (No Operation):**
- 스케줄링 거의 안 함, FIFO
- SSD, NVMe에 권장

**2. deadline:**
- 읽기/쓰기 마감 시간 보장
- 범용적으로 좋음

**3. CFQ (Completely Fair Queuing):**
- 프로세스 간 공평하게 I/O 분배
- 일반 워크로드

**4. kyber (최신 커널):**
- 응답 시간 기반
- SSD 최적화

**확인 및 변경:**
```bash
# 현재 스케줄러
cat /sys/block/sda/queue/scheduler
[mq-deadline] kyber none

# 변경 (런타임)
echo noop > /sys/block/sda/queue/scheduler

# 영구 변경 (grub)
# /etc/default/grub
GRUB_CMDLINE_LINUX="elevator=noop"
```

**PostgreSQL WAL 권장:**
- SSD: noop 또는 none
- HDD: deadline

### Direct I/O (O_DIRECT)

**일반 I/O:**
```
PostgreSQL → Page Cache → Disk
            (이중 캐싱)
```

**Direct I/O:**
```
PostgreSQL → Disk (Page Cache 우회)
```

**PostgreSQL의 지원:**
- WAL은 기본적으로 Direct I/O 사용 안 함
- `wal_sync_method = open_sync`로 간접적 지원

**장단점:**
- 장점: 이중 캐싱 제거, 예측 가능한 지연
- 단점: OS의 readahead 등 최적화 상실

### WAL 전용 디스크 분리

**아키텍처:**
```
/dev/sda1 → /var/lib/postgresql/data  (데이터 파일)
/dev/sdb1 → /var/lib/postgresql/wal   (WAL 전용)
```

**설정:**
```bash
# WAL 디렉토리 이동
initdb -D /var/lib/postgresql/data --waldir=/var/lib/postgresql/wal

# 또는 심볼릭 링크
mv /var/lib/postgresql/data/pg_wal /mnt/wal_disk/pg_wal
ln -s /mnt/wal_disk/pg_wal /var/lib/postgresql/data/pg_wal
```

**장점:**
1. WAL 순차 쓰기와 데이터 랜덤 I/O 격리
2. WAL을 빠른 SSD에, 데이터를 저렴한 HDD에
3. 디스크 대역폭 분산

**주의:**
- 두 디스크 모두 안정적이어야 함
- 한쪽 디스크 실패 시 데이터베이스 중단

## 실습 SQL

### 1. 현재 WAL 상태 확인

```sql
-- 현재 WAL 쓰기 위치
SELECT pg_current_wal_lsn();
--  10/A1B2C3D4

-- 현재 WAL 삽입 위치 (버퍼)
SELECT pg_current_wal_insert_lsn();
--  10/A1B2C3D8

-- 마지막 WAL 수신 위치 (복제 서버에서)
SELECT pg_last_wal_receive_lsn();

-- 마지막 WAL 재생 위치 (복제 서버에서)
SELECT pg_last_wal_replay_lsn();
```

### 2. WAL 설정 확인

```sql
-- WAL 관련 설정 모두 보기
SELECT name, setting, unit, category
FROM pg_settings
WHERE category LIKE '%WAL%'
ORDER BY category, name;

-- 주요 설정
SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
    'wal_level',
    'wal_buffers',
    'wal_compression',
    'full_page_writes',
    'wal_writer_delay',
    'checkpoint_timeout',
    'max_wal_size',
    'min_wal_size',
    'checkpoint_completion_target'
);

            name             | setting | unit
-----------------------------+---------+------
 wal_level                   | replica |
 wal_buffers                 | 2048    | 8kB
 wal_compression             | on      |
 full_page_writes            | on      |
 wal_writer_delay            | 200     | ms
 checkpoint_timeout          | 300     | s
 max_wal_size                | 1024    | MB
 min_wal_size                | 80      | MB
 checkpoint_completion_target| 0.9     |
```

### 3. Checkpoint 통계 (PostgreSQL 17)

```sql
-- checkpointer 통계
SELECT
    num_timed AS scheduled_checkpoints,
    num_requested AS forced_checkpoints,
    buffers_written,
    round((write_time / 1000.0)::numeric, 2) AS write_time_sec,
    round((sync_time / 1000.0)::numeric, 2) AS sync_time_sec,
    pg_size_pretty(buffers_written * 8192) AS data_written,
    stats_reset
FROM pg_stat_checkpointer;

 scheduled_checkpoints | forced_checkpoints | buffers_written | write_time_sec | sync_time_sec | data_written | stats_reset
-----------------------+--------------------+-----------------+----------------+---------------+--------------+-------------
                   120 |                 15 |         5000000 |          45.23 |         12.45 | 39 GB        | 2024-01-01

-- forced_checkpoints가 많다면 max_wal_size 증가 필요
```

### 4. WAL 통계

```sql
-- WAL 생성 통계
SELECT
    wal_records,        -- WAL 레코드 수
    wal_fpi,            -- Full Page Image 수
    wal_bytes,          -- WAL 바이트 수
    pg_size_pretty(wal_bytes) AS wal_size,
    wal_buffers_full,   -- WAL 버퍼 가득 참 횟수
    stats_reset
FROM pg_stat_wal;

 wal_records |  wal_fpi  |    wal_bytes     | wal_size  | wal_buffers_full | stats_reset
-------------+-----------+------------------+-----------+------------------+-------------
   123456789 | 987654    | 123456789012     | 115 GB    |              123 | 2024-01-01

-- wal_buffers_full > 0 → wal_buffers 증가 고려
```

### 5. 마지막 체크포인트 정보

```sql
-- pg_control_checkpoint() 함수 (PostgreSQL 17)
SELECT
    checkpoint_lsn,
    redo_lsn,
    timeline_id,
    prev_timeline_id,
    checkpoint_time
FROM pg_control_checkpoint();

 checkpoint_lsn | redo_lsn  | timeline_id | prev_timeline_id |     checkpoint_time
----------------+-----------+-------------+------------------+-------------------------
 10/AB000000    | 10/AA000000|           1 |                0 | 2024-01-31 15:30:00+09
```

### 6. WAL 아카이빙 상태

```sql
-- 아카이빙 통계
SELECT
    archived_count,     -- 아카이빙 완료 파일 수
    last_archived_wal,  -- 마지막 아카이빙 파일
    last_archived_time, -- 아카이빙 시간
    failed_count,       -- 실패 횟수
    last_failed_wal,    -- 마지막 실패 파일
    last_failed_time,
    stats_reset
FROM pg_stat_archiver;

 archived_count |   last_archived_wal    |   last_archived_time    | failed_count
----------------+------------------------+-------------------------+--------------
           5000 | 000000010000000A00000042| 2024-01-31 15:30:00+09 |            0

-- failed_count > 0 → archive_command 문제 확인
```

### 7. 복제 슬롯과 WAL 보존

```sql
-- 복제 슬롯 목록
SELECT
    slot_name,
    slot_type,
    active,
    restart_lsn,
    confirmed_flush_lsn,
    wal_status,
    safe_wal_size
FROM pg_replication_slots;

   slot_name   | slot_type | active | restart_lsn | wal_status | safe_wal_size
---------------+-----------+--------+-------------+------------+---------------
 replica_slot  | physical  | t      | 10/AA000000 | reserved   | 256 MB

-- wal_status:
--   reserved: WAL 보존 중
--   extended: max_slot_wal_keep_size 초과, 확장 보존
--   unreserved: 보존 안 함 (위험)
--   lost: WAL 삭제됨 (복제 불가)
```

### 8. WAL 파일 목록 확인

```sql
-- pg_ls_waldir() 함수로 파일 목록
SELECT
    name,
    size,
    modification
FROM pg_ls_waldir()
ORDER BY modification DESC
LIMIT 10;

          name           |   size   |      modification
-------------------------+----------+-------------------------
 000000010000000A00000045 | 16777216 | 2024-01-31 15:30:00+09
 000000010000000A00000044 | 16777216 | 2024-01-31 15:25:00+09
 000000010000000A00000043 | 16777216 | 2024-01-31 15:20:00+09

-- 16777216 bytes = 16 MB (wal_segment_size)

-- 전체 WAL 크기
SELECT pg_size_pretty(sum(size)) AS total_wal_size
FROM pg_ls_waldir();

 total_wal_size
----------------
 256 MB
```

### 9. 이커머스 시나리오: 주문 처리 WAL 추적

```sql
-- 트랜잭션 전 LSN 기록
SELECT pg_current_wal_lsn() AS lsn_before;
--  10/A1000000

-- 주문 생성
BEGIN;

INSERT INTO orders (user_id, total_amount, status)
VALUES (12345, 99.99, 'pending')
RETURNING id;

INSERT INTO order_items (order_id, product_id, quantity, price)
VALUES (currval('orders_id_seq'), 100, 2, 49.99);

UPDATE inventory SET quantity = quantity - 2 WHERE product_id = 100;

COMMIT;

-- 트랜잭션 후 LSN
SELECT pg_current_wal_lsn() AS lsn_after;
--  10/A1001234

-- WAL 크기 계산
SELECT pg_wal_lsn_diff('10/A1001234', '10/A1000000') AS wal_bytes;
--  4660 bytes

-- 이 트랜잭션이 약 4.6KB의 WAL 생성
```

### 10. 수동 체크포인트 및 영향 관찰

```sql
-- 체크포인트 전 통계
SELECT num_timed, num_requested, buffers_written
FROM pg_stat_checkpointer;

 num_timed | num_requested | buffers_written
-----------+---------------+-----------------
       100 |            10 |         5000000

-- 수동 체크포인트 (주의: 시스템 부하)
CHECKPOINT;

-- 체크포인트 후 통계
SELECT num_timed, num_requested, buffers_written
FROM pg_stat_checkpointer;

 num_timed | num_requested | buffers_written
-----------+---------------+-----------------
       100 |            11 |         5023456  -- 증가

-- num_requested가 1 증가
-- buffers_written도 증가
```

## 직접 확인해보기

### 실습 1: WAL 파일 생성 관찰

```bash
# 터미널 1: WAL 디렉토리 모니터링
watch -n 1 'ls -lh $PGDATA/pg_wal/*.wal 2>/dev/null | tail -5'
```

```sql
-- 터미널 2: 대량 INSERT로 WAL 생성
CREATE TABLE wal_test (id SERIAL, data TEXT);

INSERT INTO wal_test (data)
SELECT repeat('X', 1000) FROM generate_series(1, 100000);

-- 터미널 1에서 WAL 파일 증가 확인
```

```bash
# WAL 파일 수와 크기
ls -lh $PGDATA/pg_wal/*.wal | wc -l
du -sh $PGDATA/pg_wal
```

### 실습 2: pg_waldump로 WAL 내용 확인

```bash
# 최신 WAL 파일명 찾기
LATEST_WAL=$(ls -t $PGDATA/pg_wal/0000* | head -1)

# WAL 덤프
pg_waldump $LATEST_WAL | head -50
```

**출력 예시:**
```
rmgr: Heap        len (rec/tot):     54/    54, tx:       1001, lsn: 10/A1000028, prev 10/A1000000, desc: INSERT off 1, blkref #0: rel 1663/16384/16385 blk 0
rmgr: Transaction len (rec/tot):     34/    34, tx:       1001, lsn: 10/A1000060, prev 10/A1000028, desc: COMMIT 2024-01-31 15:30:00.123456 KST
rmgr: Heap        len (rec/tot):     54/    54, tx:       1002, lsn: 10/A1000084, prev 10/A1000060, desc: UPDATE off 1, blkref #0: rel 1663/16384/16385 blk 0
```

**분석:**
- `rmgr: Heap` → 테이블 데이터 변경
- `INSERT off 1` → 첫 번째 슬롯에 INSERT
- `tx: 1001` → 트랜잭션 ID
- `lsn: 10/A1000028` → WAL 위치
- `rel 1663/16384/16385` → tablespace/database/relation

**특정 테이블의 WAL만 필터:**
```bash
pg_waldump $LATEST_WAL | grep "rel 1663/16384/16385"
```

### 실습 3: LSN 증가 속도 측정

```sql
-- 현재 LSN 기록
SELECT pg_current_wal_lsn() AS start_lsn;
--  10/A1000000

-- 10초 대기
SELECT pg_sleep(10);

-- 다시 LSN 확인
SELECT pg_current_wal_lsn() AS end_lsn;
--  10/A1123456

-- 증가량 계산 (bytes/sec)
SELECT
    pg_wal_lsn_diff('10/A1123456', '10/A1000000') AS bytes_diff,
    pg_wal_lsn_diff('10/A1123456', '10/A1000000') / 10.0 AS bytes_per_sec,
    pg_size_pretty(pg_wal_lsn_diff('10/A1123456', '10/A1000000')::bigint / 10) AS rate;

 bytes_diff | bytes_per_sec |  rate
------------+---------------+--------
    1193046 |      119304.6 | 116 kB/s

-- WAL 생성 속도: 116 KB/s
```

### 실습 4: Full Page Writes 효과 확인

```sql
-- FPW 카운터 리셋
SELECT pg_stat_reset_shared('wal');

-- 체크포인트 실행
CHECKPOINT;

-- 테이블 대량 수정 (첫 번째 수정 시 FPW 발생)
UPDATE wal_test SET data = 'Updated' WHERE id <= 1000;

-- WAL 통계 확인
SELECT
    wal_records,
    wal_fpi AS full_page_images,
    pg_size_pretty(wal_bytes) AS wal_generated
FROM pg_stat_wal;

 wal_records | full_page_images | wal_generated
-------------+------------------+---------------
        1000 |              100 | 5 MB

-- 같은 페이지 다시 수정 (FPW 발생 안 함)
UPDATE wal_test SET data = 'Updated2' WHERE id <= 1000;

SELECT
    wal_records,
    wal_fpi,
    pg_size_pretty(wal_bytes)
FROM pg_stat_wal;

 wal_records | wal_fpi | wal_generated
-------------+---------+---------------
        2000 |     100 | 6 MB  -- FPW 증가 없음
```

### 실습 5: Checkpoint 타이밍 관찰

```bash
# PostgreSQL 로그에서 체크포인트 메시지 확인
tail -f $PGDATA/log/postgresql-*.log | grep checkpoint
```

**설정 (postgresql.conf):**
```
log_checkpoints = on
```

**로그 예시:**
```
2024-01-31 15:30:00 KST [12345]: LOG:  checkpoint starting: time
2024-01-31 15:32:30 KST [12345]: LOG:  checkpoint complete: wrote 50000 buffers (390.6 MB); 0 WAL file(s) added, 0 removed, 5 recycled; write=145.234 s, sync=2.345 s, total=150.123 s; sync files=1234, longest=0.123 s, average=0.002 s; distance=1024 MB, estimate=1024 MB
```

**분석:**
- `wrote 50000 buffers (390.6 MB)`: 더티 페이지 쓰기
- `write=145.234 s`: 쓰기 시간 (checkpoint_completion_target으로 분산)
- `sync=2.345 s`: fsync 시간
- `distance=1024 MB`: 이전 체크포인트 이후 WAL 크기

### 실습 6: WAL 압축 효과 측정

```sql
-- WAL 압축 비활성화
ALTER SYSTEM SET wal_compression = off;
SELECT pg_reload_conf();

-- 통계 리셋
SELECT pg_stat_reset_shared('wal');

-- 대량 데이터 삽입 (압축 가능한 데이터)
INSERT INTO wal_test (data)
SELECT repeat('AAAA', 250) FROM generate_series(1, 10000);

-- WAL 크기 확인
SELECT pg_size_pretty(wal_bytes) AS wal_without_compression
FROM pg_stat_wal;

 wal_without_compression
-------------------------
 50 MB

-- WAL 압축 활성화
ALTER SYSTEM SET wal_compression = on;
SELECT pg_reload_conf();

-- 통계 리셋
SELECT pg_stat_reset_shared('wal');

-- 같은 데이터 삽입
TRUNCATE wal_test;
INSERT INTO wal_test (data)
SELECT repeat('AAAA', 250) FROM generate_series(1, 10000);

-- WAL 크기 확인
SELECT pg_size_pretty(wal_bytes) AS wal_with_compression
FROM pg_stat_wal;

 wal_with_compression
----------------------
 15 MB  -- 70% 감소!
```

### 실습 7: 복제 슬롯과 WAL 보존

```sql
-- 물리 복제 슬롯 생성
SELECT pg_create_physical_replication_slot('test_slot');

-- 슬롯 상태 확인
SELECT slot_name, restart_lsn, wal_status
FROM pg_replication_slots;

 slot_name | restart_lsn | wal_status
-----------+-------------+------------
 test_slot | 10/A1000000 | reserved

-- 대량 WAL 생성
INSERT INTO wal_test SELECT generate_series(1, 1000000);

-- WAL 파일이 보존되는지 확인
SELECT count(*) FROM pg_ls_waldir();
-- 많은 파일이 유지됨 (슬롯이 restart_lsn부터 보존)

-- 슬롯 삭제
SELECT pg_drop_replication_slot('test_slot');

-- 체크포인트 후 WAL 정리
CHECKPOINT;

-- WAL 파일 감소 확인
SELECT count(*) FROM pg_ls_waldir();
```

### 실습 8: WAL 버퍼 튜닝

```sql
-- 현재 설정
SHOW wal_buffers;
--  16MB (2048 * 8KB)

-- WAL 버퍼 가득 참 횟수 확인
SELECT wal_buffers_full FROM pg_stat_wal;
--  1234  -- 0보다 크면 증가 필요

-- 설정 변경 (재시작 필요)
ALTER SYSTEM SET wal_buffers = '32MB';
-- pg_ctl restart

-- 다시 확인
SELECT wal_buffers_full FROM pg_stat_wal;
--  0  -- 개선됨
```

## 실무 팁

### 1. Checkpoint 튜닝 전략

**기본 원칙:**
- `checkpoint_completion_target = 0.9` 유지 (스파이크 방지)
- `max_wal_size`는 크게, `checkpoint_timeout`은 길게 (쓰기 부하 감소)
- 하지만 복구 시간과 WAL 공간 고려

**쓰기 집약적 워크로드 (OLTP):**
```sql
checkpoint_timeout = 15min
max_wal_size = 4GB
min_wal_size = 1GB
```

**읽기 위주 (OLAP):**
```sql
checkpoint_timeout = 30min
max_wal_size = 8GB
```

**모니터링:**
```sql
-- 요청 체크포인트 비율이 30% 이상이면 max_wal_size 증가
SELECT
    num_requested::float / (num_timed + num_requested) AS requested_ratio
FROM pg_stat_checkpointer;
```

### 2. WAL 압축 활성화

```sql
-- 거의 항상 켜는 것이 유리
wal_compression = on

-- 예외:
-- - CPU가 극도로 제한적인 환경
-- - 이미 압축된 데이터 (이미지, 동영상)
```

**효과:**
- FPW 크기 50-70% 감소
- WAL 전송 대역폭 감소 (복제 환경)
- CPU 오버헤드는 미미

### 3. WAL 아카이빙 설정

**연속 아카이빙 (PITR 백업):**
```sql
-- postgresql.conf
wal_level = replica
archive_mode = on
archive_command = 'cp %p /mnt/wal_archive/%f'
archive_timeout = 300  -- 5분마다 강제 아카이빙
```

**S3로 아카이빙 (AWS):**
```sql
archive_command = 'aws s3 cp %p s3://my-bucket/wal/%f'
```

**모니터링:**
```sql
-- 아카이빙 실패 감지
SELECT failed_count, last_failed_wal
FROM pg_stat_archiver;
```

### 4. 복제 슬롯 관리

**주의 사항:**
- 복제 슬롯은 WAL을 무한정 보존
- Standby가 다운되면 Primary의 WAL 폭증

**안전 장치:**
```sql
-- PostgreSQL 13+
max_slot_wal_keep_size = 10GB

-- 10GB 초과 시 슬롯 무효화 (복제 중단하지만 Primary 보호)
```

**모니터링:**
```sql
-- 슬롯 상태 확인
SELECT
    slot_name,
    active,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / 1024 / 1024 AS lag_mb,
    wal_status
FROM pg_replication_slots;

-- wal_status = 'extended' 또는 'unreserved'면 경고
```

### 5. WAL 전용 디스크

```bash
# 초기화 시 WAL 디렉토리 분리
initdb -D /var/lib/postgresql/data --waldir=/mnt/fast_ssd/pg_wal

# 또는 기존 클러스터 이동 (주의: 다운타임)
pg_ctl stop
mv /var/lib/postgresql/data/pg_wal /mnt/fast_ssd/pg_wal
ln -s /mnt/fast_ssd/pg_wal /var/lib/postgresql/data/pg_wal
pg_ctl start
```

**효과:**
- WAL 쓰기와 데이터 읽기 I/O 분리
- 쓰기 지연 감소

### 6. 대량 INSERT 최적화

```sql
-- WAL 최소화 방법
BEGIN;

-- UNLOGGED 테이블 사용 (WAL 생성 안 함)
CREATE UNLOGGED TABLE temp_data (id INT, data TEXT);

INSERT INTO temp_data SELECT ...;  -- 빠름

-- 작업 후 LOGGED로 변경
ALTER TABLE temp_data SET LOGGED;  -- 전체 테이블 WAL 기록

COMMIT;

-- 또는 COPY 사용 (최적화된 WAL 생성)
COPY target_table FROM '/path/to/data.csv';
```

### 7. Synchronous Commit 조정

```sql
-- 기본 (가장 안전, 가장 느림)
synchronous_commit = on

-- 트랜잭션 손실 허용 가능한 경우 (로그 등)
synchronous_commit = off  -- 최대 3배 빠름, 하지만 크래시 시 최근 트랜잭션 손실

-- 복제 환경: 로컬 fsync는 하되, 복제 대기는 안 함
synchronous_commit = local

-- 세션별 조정
SET LOCAL synchronous_commit = off;
INSERT INTO event_logs ...;  -- 이 세션만 비동기
```

**주의:**
- `synchronous_commit = off`여도 데이터 일관성은 유지
- 단지 최근 수백 ms의 커밋이 크래시 시 손실 가능

### 8. pg_waldump로 장애 분석

**크래시 후 어떤 트랜잭션이 손실되었는지 확인:**
```bash
# 크래시 직전 WAL 파일
CRASH_WAL=000000010000000A00000042

# 커밋 트랜잭션 추출
pg_waldump $PGDATA/pg_wal/$CRASH_WAL | grep COMMIT

# 특정 테이블 변경 추적
pg_waldump $PGDATA/pg_wal/$CRASH_WAL | grep "rel 1663/16384/16385"
```

### 9. 복구 테스트

**정기적으로 복구 테스트를 수행해야 합니다!**

```bash
# 1. 베이스 백업
pg_basebackup -D /backup/pgdata -Fp -Xs -P

# 2. WAL 아카이브 확인
ls /mnt/wal_archive/ | wc -l

# 3. 복구 테스트 (별도 서버에서)
cp -r /backup/pgdata /test/pgdata
cat > /test/pgdata/recovery.signal <<EOF
restore_command = 'cp /mnt/wal_archive/%f %p'
recovery_target_time = '2024-01-31 15:00:00'
EOF

# 4. PostgreSQL 시작
pg_ctl -D /test/pgdata start

# 5. 로그 확인
tail -f /test/pgdata/log/postgresql-*.log
# "database system is ready to accept connections" 확인
```

### 10. 모니터링 및 알람

```sql
-- 모니터링 뷰 생성
CREATE VIEW v_wal_health AS
SELECT
    -- WAL 생성 속도
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0') /
        EXTRACT(epoch FROM (now() - pg_postmaster_start_time()))
    ) AS wal_rate,

    -- 체크포인트 건강도
    CASE
        WHEN num_requested::float / NULLIF(num_timed + num_requested, 0) > 0.3
        THEN 'WARNING'
        ELSE 'OK'
    END AS checkpoint_health,

    -- WAL 파일 수
    (SELECT count(*) FROM pg_ls_waldir()) AS wal_file_count,

    -- WAL 총 크기
    pg_size_pretty((SELECT sum(size) FROM pg_ls_waldir())) AS total_wal_size,

    -- 아카이빙 실패
    failed_count AS archive_failures
FROM pg_stat_checkpointer, pg_stat_archiver;

-- 정기 체크
SELECT * FROM v_wal_health;
```

**알람 스크립트:**
```bash
#!/bin/bash
# wal_monitor.sh

FAILURES=$(psql -t -c "SELECT failed_count FROM pg_stat_archiver;")
if [ $FAILURES -gt 0 ]; then
    echo "ALERT: WAL archiving failed $FAILURES times!"
fi

WAL_FILES=$(psql -t -c "SELECT count(*) FROM pg_ls_waldir();")
if [ $WAL_FILES -gt 100 ]; then
    echo "WARNING: Too many WAL files ($WAL_FILES)"
fi
```

## 참고 링크

### 공식 문서 (PostgreSQL 17)

1. **Write-Ahead Logging (WAL)**
   https://www.postgresql.org/docs/17/wal.html
   - Chapter 28: Reliability and the Write-Ahead Log
   - 28.3 WAL Configuration
   - 28.4 WAL Internals

2. **Checkpoints**
   https://www.postgresql.org/docs/17/runtime-config-wal.html#RUNTIME-CONFIG-WAL-CHECKPOINTS

3. **pg_waldump**
   https://www.postgresql.org/docs/17/pgwaldump.html

4. **pg_stat_checkpointer (PostgreSQL 17)**
   https://www.postgresql.org/docs/17/monitoring-stats.html#MONITORING-PG-STAT-CHECKPOINTER-VIEW

5. **Continuous Archiving and PITR**
   https://www.postgresql.org/docs/17/continuous-archiving.html

### 추천 자료

- "The Internals of PostgreSQL - Chapter 9: WAL"
  https://www.interdb.jp/pg/pgsql09.html

- "PostgreSQL 14 Internals" by Egor Rogov
  Chapter on WAL and Recovery

- Bruce Momjian's "Inside the PostgreSQL Query Optimizer"
  WAL 섹션

### 도구

- **pgBackRest**: 백업/복구 도구 (WAL 아카이빙 포함)
  https://pgbackrest.org/

- **Barman**: PostgreSQL 백업 관리
  https://www.pgbarman.org/

- **wal-g**: WAL 아카이빙 도구 (S3 지원)
  https://github.com/wal-g/wal-g

## 다이어그램 참조

```
diagrams/03-wal-flow.drawio
```

다이어그램 내용:
1. WAL 쓰기 전체 흐름 (트랜잭션 → WAL → 데이터 파일)
2. Checkpoint 타이밍과 WAL 재활용
3. Full Page Writes 동작 방식
4. 복제와 WAL 전송

## 마무리

WAL은 PostgreSQL의 신뢰성과 성능의 핵심입니다.

**핵심 포인트:**
1. **WAL은 순차 쓰기** → 데이터 파일 랜덤 쓰기보다 훨씬 빠름
2. **Checkpoint로 동기화** → 복구 시간과 성능의 균형
3. **Full Page Writes로 안전성** → Torn page 방지
4. **복제와 백업의 기반** → WAL 아카이빙과 슬롯 관리 필수
5. **모니터링과 튜닝** → pg_stat_checkpointer, pg_stat_wal 활용

WAL 설정을 이해하고 최적화하면, 데이터 안전성을 유지하면서도 높은 쓰기 성능을 달성할 수 있습니다.

다음 단계로는 복제(Replication), 백업/복구(PITR), 인덱싱 전략 등을 학습하면 PostgreSQL 전문가로 나아갈 수 있습니다.
