# 07. 쿼리 최적화와 EXPLAIN

## 한줄 요약
PostgreSQL의 쿼리 플래너와 실행 계획을 이해하고 EXPLAIN을 활용하여 느린 쿼리를 분석하고 최적화하는 방법을 다룬다.

## 왜 알아야 하는가

### 성능 문제의 근본 원인
- 대부분의 데이터베이스 성능 문제는 비효율적인 쿼리에서 발생
- 인덱스를 추가하는 것만으로는 불충분, 쿼리 플래너의 동작 이해 필요
- 실행 계획을 읽지 못하면 왜 느린지, 어떻게 개선할지 알 수 없음

### 실무에서의 중요성
```
시나리오: 이커머스 주문 조회 쿼리가 5초 소요
→ EXPLAIN ANALYZE로 분석
→ Sequential Scan 발견
→ 적절한 인덱스 추가
→ 0.1초로 단축 (50배 개선)
```

### PostgreSQL 17의 개선사항
- CTE 최적화: WITH 구문의 성능 개선
- GROUP BY 열 재정렬: 카디널리티 기반 자동 최적화
- 증분 백업 최적화로 전체 시스템 성능 향상

## 핵심 개념

### 1. EXPLAIN 기본 구조

#### EXPLAIN 출력 읽는 법
```sql
EXPLAIN
SELECT * FROM orders WHERE user_id = 1000;
```

출력 예시:
```
Seq Scan on orders  (cost=0.00..1234.56 rows=10 width=128)
  Filter: (user_id = 1000)
```

구성 요소:
- **노드 타입**: Seq Scan (순차 스캔)
- **cost**: 0.00..1234.56 (시작 비용..총 비용)
- **rows**: 10 (예상 반환 행 수)
- **width**: 128 (평균 행 크기, 바이트)

#### Cost 단위 이해
```
cost = 1.0 = 한 페이지(8KB)를 순차적으로 읽는 비용
```

파라미터별 비용:
- `seq_page_cost = 1.0`: 순차 읽기
- `random_page_cost = 4.0`: 랜덤 읽기 (디스크 기준)
- `cpu_tuple_cost = 0.01`: 행 처리 비용
- `cpu_operator_cost = 0.0025`: 연산자 실행 비용

### 2. EXPLAIN ANALYZE

#### 예측 vs 실제 측정
```sql
EXPLAIN ANALYZE
SELECT o.order_id, u.username, o.total_amount
FROM orders o
JOIN users u ON o.user_id = u.user_id
WHERE o.created_at >= '2024-01-01'
  AND o.status = 'completed';
```

출력:
```
Hash Join  (cost=45.00..1289.45 rows=500 width=52)
           (actual time=2.345..15.678 rows=523 loops=1)
  Hash Cond: (o.user_id = u.user_id)
  ->  Seq Scan on orders o  (cost=0.00..1200.00 rows=520 width=40)
                             (actual time=0.123..10.234 rows=523 loops=1)
        Filter: ((created_at >= '2024-01-01') AND (status = 'completed'))
        Rows Removed by Filter: 4477
  ->  Hash  (cost=30.00..30.00 rows=1000 width=20)
            (actual time=2.100..2.101 rows=1000 loops=1)
        Buckets: 1024  Batches: 1  Memory Usage: 65kB
        ->  Seq Scan on users u  (cost=0.00..30.00 rows=1000 width=20)
                                  (actual time=0.010..1.234 rows=1000 loops=1)
Planning Time: 0.234 ms
Execution Time: 15.890 ms
```

주요 지표:
- **actual time**: 실제 소요 시간 (ms)
- **rows**: 실제 반환 행 수 (예측과 비교)
- **loops**: 노드가 실행된 횟수
- **Rows Removed by Filter**: 필터로 제거된 행 (비효율 지표)

#### BUFFERS 옵션
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM products WHERE category_id = 10;
```

출력:
```
Index Scan using idx_products_category_id on products
  (cost=0.42..8.45 rows=1 width=200)
  (actual time=0.015..0.020 rows=1 loops=1)
  Index Cond: (category_id = 10)
  Buffers: shared hit=4
Planning:
  Buffers: shared hit=12
Planning Time: 0.123 ms
Execution Time: 0.045 ms
```

버퍼 통계 해석:
- **shared hit**: shared_buffers에서 찾음 (메모리 히트)
- **shared read**: 디스크에서 읽음 (또는 OS 캐시)
- **shared dirtied**: 수정된 버퍼 수
- **shared written**: 디스크에 쓴 버퍼 수
- **temp read/written**: 임시 파일 I/O (정렬, 해시 조인 시)

### 3. 주요 스캔 방식

#### Sequential Scan (순차 스캔)
```sql
-- 전체 테이블 순차 읽기
EXPLAIN ANALYZE
SELECT * FROM orders WHERE total_amount > 100;
```

특징:
- 테이블의 모든 페이지를 순차적으로 읽음
- 작은 테이블이거나 대부분의 행이 필요할 때 효율적
- 인덱스보다 빠를 수 있음 (대량 데이터 조회 시)

#### Index Scan (인덱스 스캔)
```sql
-- 인덱스를 통한 조회
CREATE INDEX idx_orders_user_id ON orders(user_id);

EXPLAIN ANALYZE
SELECT * FROM orders WHERE user_id = 1000;
```

특징:
- 인덱스를 탐색 후 테이블 페이지 접근 (랜덤 I/O)
- 선택도가 낮을 때 효율적 (<10% 정도)
- 정렬된 결과 제공

#### Index Only Scan (커버링 인덱스)
```sql
-- 모든 컬럼이 인덱스에 포함
CREATE INDEX idx_orders_user_created ON orders(user_id, created_at);

EXPLAIN ANALYZE
SELECT user_id, created_at
FROM orders
WHERE user_id = 1000;
```

특징:
- 테이블 접근 없이 인덱스만으로 쿼리 처리
- Visibility Map 활용 (VACUUM으로 생성)
- 가장 빠른 스캔 방식

#### Bitmap Scan (비트맵 스캔)
```sql
-- 여러 조건 OR 연결
EXPLAIN ANALYZE
SELECT * FROM orders
WHERE user_id = 1000 OR user_id = 2000;
```

특징:
- 인덱스에서 비트맵 생성 → 정렬 → 테이블 스캔
- 여러 인덱스 조합 가능 (Bitmap OR/AND)
- 랜덤 I/O를 순차 I/O로 변환

### 4. 주요 조인 방식

#### Nested Loop Join
```sql
-- 작은 테이블과 큰 테이블 조인
EXPLAIN ANALYZE
SELECT o.*, u.username
FROM orders o
JOIN users u ON o.user_id = u.user_id
WHERE o.order_id = 12345;
```

특징:
- 외부 루프 각 행마다 내부 테이블 검색
- 작은 결과셋에 효율적
- 내부 테이블에 인덱스 필수

#### Hash Join
```sql
-- 중간 크기 테이블 조인
EXPLAIN ANALYZE
SELECT o.*, u.username
FROM orders o
JOIN users u ON o.user_id = u.user_id
WHERE o.created_at >= '2024-01-01';
```

특징:
- 작은 테이블로 해시 테이블 생성
- 큰 테이블 스캔하며 해시 조회
- work_mem 크기 중요 (메모리 부족 시 디스크 사용)

#### Merge Join
```sql
-- 대용량 테이블 조인
EXPLAIN ANALYZE
SELECT o.*, oi.*
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
ORDER BY o.order_id;
```

특징:
- 양쪽 테이블이 정렬되어 있어야 함
- 정렬 비용이 크지만 대용량 데이터에 효율적
- 이미 정렬된 인덱스가 있으면 유리

### 5. 통계 시스템

#### pg_stats 카탈로그
```sql
-- 테이블 통계 확인
SELECT schemaname, tablename, attname, n_distinct,
       most_common_vals, most_common_freqs, histogram_bounds
FROM pg_stats
WHERE tablename = 'orders' AND attname = 'status';
```

출력:
```
 attname |  n_distinct  | most_common_vals | most_common_freqs
---------+--------------+------------------+-------------------
 status  |            5 | {pending,        | {0.45,0.30,
         |              |  completed,      |  0.15,0.08,
         |              |  shipped,        |  0.015,0.005}
         |              |  cancelled,      |
         |              |  refunded}       |
```

통계 항목:
- **n_distinct**: 고유 값 개수 (카디널리티)
- **most_common_vals**: 가장 빈번한 값들
- **most_common_freqs**: 각 값의 빈도
- **histogram_bounds**: 값 분포 히스토그램
- **correlation**: 물리적 정렬과 논리적 정렬의 상관도

#### ANALYZE 실행
```sql
-- 전체 테이블 통계 수집
ANALYZE orders;

-- 특정 컬럼만
ANALYZE orders (user_id, created_at);

-- 통계 정보 확인
SELECT schemaname, tablename, last_analyze, n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE tablename = 'orders';
```

통계 수집 파라미터:
```sql
-- 샘플링 비율 설정
ALTER TABLE orders SET (autovacuum_analyze_scale_factor = 0.05);

-- 통계 상세도 설정
ALTER TABLE orders ALTER COLUMN user_id SET STATISTICS 1000;
```

### 6. Parallel Query (병렬 쿼리)

#### 병렬 실행 조건
```sql
-- 병렬 Sequential Scan
EXPLAIN ANALYZE
SELECT COUNT(*), AVG(total_amount)
FROM orders
WHERE created_at >= '2024-01-01';
```

출력:
```
Finalize Aggregate  (cost=12345.67..12345.68 rows=1 width=16)
  ->  Gather  (cost=12345.45..12345.66 rows=2 width=16)
        Workers Planned: 2
        Workers Launched: 2
        ->  Partial Aggregate  (cost=11345.45..11345.46 rows=1 width=16)
              ->  Parallel Seq Scan on orders
                    (cost=0.00..11000.00 rows=41667 width=8)
                    Filter: (created_at >= '2024-01-01')
```

병렬 처리 노드:
- **Gather**: Worker 프로세스 결과 수집
- **Parallel Seq Scan**: 병렬 순차 스캔
- **Parallel Hash Join**: 병렬 해시 조인
- **Partial Aggregate**: 부분 집계

#### 병렬 설정
```sql
-- 전역 설정
SET max_parallel_workers_per_gather = 4;  -- 쿼리당 최대 worker
SET max_parallel_workers = 8;             -- 전체 최대 worker
SET parallel_setup_cost = 1000;           -- 병렬 시작 비용
SET parallel_tuple_cost = 0.1;            -- 행 전송 비용

-- 테이블별 설정
ALTER TABLE orders SET (parallel_workers = 4);

-- 쿼리별 힌트
SET max_parallel_workers_per_gather = 0;  -- 병렬 비활성화
```

### 7. JIT 컴파일

#### JIT 활성화
```sql
-- JIT 설정
SET jit = on;
SET jit_above_cost = 100000;
SET jit_optimize_above_cost = 500000;

-- JIT 적용 확인
EXPLAIN ANALYZE
SELECT SUM(oi.quantity * pv.price)
FROM order_items oi
JOIN product_variants pv ON oi.variant_id = pv.variant_id
WHERE oi.created_at >= '2024-01-01';
```

출력:
```
...
Planning Time: 0.234 ms
JIT:
  Functions: 12
  Options: Inlining true, Optimization true, Expressions true, Deforming true
  Timing: Generation 1.234 ms, Inlining 2.345 ms, Optimization 5.678 ms, Emission 3.456 ms, Total 12.713 ms
Execution Time: 145.234 ms
```

JIT가 효과적인 경우:
- 표현식 평가가 많은 쿼리
- 대량 데이터 처리
- CPU 바운드 쿼리

### 8. PostgreSQL 17의 최적화

#### CTE 최적화
```sql
-- PostgreSQL 17: CTE가 자동으로 인라인될 수 있음
WITH recent_orders AS (
  SELECT user_id, COUNT(*) as order_count
  FROM orders
  WHERE created_at >= CURRENT_DATE - INTERVAL '30 days'
  GROUP BY user_id
)
SELECT u.username, ro.order_count
FROM users u
JOIN recent_orders ro ON u.user_id = ro.user_id
WHERE ro.order_count > 5;

-- 이전 버전: CTE가 항상 Materialize
-- v17: 필요시 인라인되어 더 나은 최적화
```

인라인 방지 (명시적 Materialize):
```sql
WITH recent_orders AS MATERIALIZED (
  SELECT user_id, COUNT(*) as order_count
  FROM orders
  WHERE created_at >= CURRENT_DATE - INTERVAL '30 days'
  GROUP BY user_id
)
SELECT u.username, ro.order_count
FROM users u
JOIN recent_orders ro ON u.user_id = ro.user_id;
```

#### GROUP BY 열 재정렬
```sql
-- PostgreSQL 17: 카디널리티가 낮은 컬럼부터 그룹화
EXPLAIN ANALYZE
SELECT status, payment_method, COUNT(*), SUM(total_amount)
FROM orders
GROUP BY status, payment_method;

-- v17 이전: 쿼리 순서대로 (status → payment_method)
-- v17: 자동 재정렬 (카디널리티 기반)
-- 예: payment_method(5) → status(6) 순서로 변경 가능
```

성능 향상:
- 해시 테이블 효율 개선
- 메모리 사용량 감소
- 대용량 GROUP BY 쿼리에서 특히 효과적

## OS/파일시스템 관점

### 1. Shared Buffers와 OS 캐시

#### 메모리 계층 구조
```
PostgreSQL 쿼리 실행
    ↓
shared_buffers (PostgreSQL 캐시)
    ↓ (shared hit)
OS Page Cache (커널 캐시)
    ↓ (shared read)
디스크 I/O
```

#### Shared Buffers
```sql
-- postgresql.conf
shared_buffers = 4GB  -- 전체 RAM의 25% 권장

-- 현재 사용량 확인
SELECT name, setting, unit, context
FROM pg_settings
WHERE name = 'shared_buffers';

-- 버퍼 사용 통계
SELECT
  c.relname,
  pg_size_pretty(count(*) * 8192) as buffered_size,
  round(100.0 * count(*) / (SELECT setting FROM pg_settings WHERE name='shared_buffers')::int, 2) as buffer_percent
FROM pg_buffercache b
JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
WHERE b.reldatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
GROUP BY c.relname
ORDER BY count(*) DESC
LIMIT 10;
```

shared_buffers 동작:
- PostgreSQL이 직접 관리하는 메모리 영역
- LRU 알고리즘으로 페이지 관리
- shared hit: 버퍼에서 찾음 (가장 빠름)
- shared read: 버퍼에 없어서 로드 필요

#### OS Page Cache
```bash
# Linux: 페이지 캐시 확인
free -h
              total        used        free      shared  buff/cache   available
Mem:           32Gi       8.0Gi       2.0Gi       100Mi        22Gi        23Gi

# 캐시 비우기 (테스트용)
echo 3 > /proc/sys/vm/drop_caches
```

OS 캐시 동작:
- shared read가 발생해도 OS 캐시에 있으면 빠름
- PostgreSQL은 OS 캐시를 활용하는 전략
- `effective_cache_size`로 플래너에게 힌트 제공

#### effective_cache_size
```sql
-- OS 캐시 포함 전체 캐시 크기 설정
-- shared_buffers + OS page cache
-- 예: RAM 32GB 시스템
ALTER SYSTEM SET effective_cache_size = '24GB';
SELECT pg_reload_conf();

-- 플래너가 인덱스 스캔 비용 계산 시 참고
-- 실제 메모리 할당은 하지 않음
```

### 2. 병렬 쿼리와 프로세스

#### Worker 프로세스 생성
```bash
# 병렬 쿼리 실행 중 프로세스 확인
ps aux | grep postgres

postgres  1234  ... postgres: user dbname [local] SELECT
postgres  1235  ... postgres: parallel worker for PID 1234
postgres  1236  ... postgres: parallel worker for PID 1234
```

프로세스 구조:
- Leader 프로세스: 쿼리 조정, 결과 수집
- Worker 프로세스: fork()로 생성, 실제 작업 수행
- IPC: 공유 메모리로 통신

#### CPU 코어와 병렬도
```sql
-- CPU 코어 수 확인
SELECT COUNT(*) FROM pg_stat_activity WHERE backend_type = 'parallel worker';

-- 시스템 정보
SHOW max_worker_processes;  -- 백그라운드 worker 포함 전체
SHOW max_parallel_workers;   -- 병렬 쿼리용 최대 수
SHOW max_parallel_workers_per_gather;  -- 쿼리당 최대 수

-- 권장 설정
-- max_worker_processes = CPU 코어 수 * 2
-- max_parallel_workers = CPU 코어 수
-- max_parallel_workers_per_gather = 4
```

병렬 처리 오버헤드:
- 프로세스 생성 비용 (fork)
- 컨텍스트 스위칭
- 결과 수집 및 병합

### 3. I/O 패턴

#### Sequential I/O vs Random I/O
```sql
-- Sequential Scan: 순차 I/O
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders;

Seq Scan on orders  (cost=0.00..1000.00 rows=50000 width=128)
  (actual time=0.010..5.234 rows=50000 loops=1)
  Buffers: shared read=500  -- 500개 페이지 순차 읽기

-- Index Scan: 랜덤 I/O
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE user_id IN (1,2,3,4,5);

Index Scan using idx_orders_user_id on orders
  (cost=0.42..25.67 rows=5 width=128)
  (actual time=0.234..1.567 rows=5 loops=1)
  Buffers: shared read=15  -- 15개 페이지 랜덤 읽기
```

디스크 특성:
- HDD: 순차 읽기 100-200MB/s, 랜덤 읽기 1-2MB/s
- SSD: 순차 500-3500MB/s, 랜덤 300-500MB/s
- NVMe: 순차 3000-7000MB/s, 랜덤 2000-4000MB/s

#### 임시 파일 I/O
```sql
-- 대용량 정렬로 임시 파일 사용
SET work_mem = '64MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders ORDER BY created_at;

Sort  (cost=5000.00..5125.00 rows=50000 width=128)
      (actual time=234.567..345.678 rows=50000 loops=1)
  Sort Key: created_at
  Sort Method: external merge  Disk: 8192kB
  Buffers: shared read=500, temp read=1024 written=1024

-- temp read/written: 임시 파일 사용 (느림)
-- work_mem 증가로 메모리 정렬 가능
```

### 4. 통계와 파일

#### 통계 파일 위치
```bash
# 통계 파일 디렉토리
cd $PGDATA/pg_stat

ls -lh
-rw------- 1 postgres postgres 234K pg_stat_tmp/db_0.stat
-rw------- 1 postgres postgres  12K pg_stat_tmp/global.stat

# 통계 파일은 주기적으로 갱신
```

통계 수집 설정:
```sql
-- 통계 수집 레벨
SHOW track_activities;  -- 현재 쿼리 추적
SHOW track_counts;      -- 행 접근 통계
SHOW track_io_timing;   -- I/O 시간 측정 (오버헤드 있음)

-- I/O 타이밍 활성화
ALTER SYSTEM SET track_io_timing = on;
SELECT pg_reload_conf();

-- 이후 EXPLAIN ANALYZE에서 I/O 시간 표시
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders;
```

## 실습 SQL

### 실습 1: 기본 EXPLAIN 분석

#### Step 1: 느린 쿼리 작성
```sql
-- 인덱스 없는 상태에서 조회
SELECT o.order_id, o.total_amount, u.username, u.email
FROM orders o
JOIN users u ON o.user_id = u.user_id
WHERE o.status = 'completed'
  AND o.created_at >= '2024-01-01'
  AND u.email LIKE '%@gmail.com'
ORDER BY o.created_at DESC
LIMIT 10;
```

#### Step 2: 실행 계획 확인
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.order_id, o.total_amount, u.username, u.email
FROM orders o
JOIN users u ON o.user_id = u.user_id
WHERE o.status = 'completed'
  AND o.created_at >= '2024-01-01'
  AND u.email LIKE '%@gmail.com'
ORDER BY o.created_at DESC
LIMIT 10;
```

#### Step 3: 문제점 파악
```sql
-- 예상 출력 분석
Limit  (cost=12345.67..12345.69 rows=10 width=150)
       (actual time=234.567..234.890 rows=10 loops=1)
  ->  Sort  (cost=12345.67..12456.78 rows=500 width=150)
            (actual time=234.560..234.880 rows=10 loops=1)
        Sort Key: o.created_at DESC
        Sort Method: top-N heapsort  Memory: 25kB
        ->  Hash Join  (cost=1234.56..11234.56 rows=500 width=150)
                       (actual time=12.345..230.456 rows=523 loops=1)
              Hash Cond: (o.user_id = u.user_id)
              ->  Seq Scan on orders o  (cost=0.00..9000.00 rows=1000 width=128)
                                        (actual time=0.234..180.567 rows=1045 loops=1)
                    Filter: ((status = 'completed') AND (created_at >= '2024-01-01'))
                    Rows Removed by Filter: 48955
              ->  Hash  (cost=1000.00..1000.00 rows=100 width=50)
                        (actual time=10.234..10.235 rows=102 loops=1)
                    Buckets: 1024  Batches: 1  Memory Usage: 12kB
                    ->  Seq Scan on users u  (cost=0.00..1000.00 rows=100 width=50)
                                              (actual time=0.123..9.876 rows=102 loops=1)
                          Filter: (email LIKE '%@gmail.com')
                          Rows Removed by Filter: 9898
  Buffers: shared hit=1234 read=567
Planning Time: 0.456 ms
Execution Time: 234.987 ms
```

문제점:
1. **Seq Scan on orders**: 50,000행 중 1,045행만 필요 (선택도 2%)
2. **Rows Removed by Filter: 48955**: 대부분 버림
3. **Seq Scan on users**: 10,000행 중 102행만 필요
4. **Rows Removed by Filter: 9898**: LIKE '%@...' 패턴은 인덱스 불가

### 실습 2: 인덱스 최적화

#### Step 1: 인덱스 생성
```sql
-- orders 테이블 복합 인덱스
CREATE INDEX idx_orders_status_created
ON orders(status, created_at DESC);

-- user_id는 FK 인덱스로 이미 존재한다고 가정
-- users.email은 부분 일치라 인덱스 효과 제한적

-- 통계 갱신
ANALYZE orders;
ANALYZE users;
```

#### Step 2: 개선된 실행 계획 확인
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.order_id, o.total_amount, u.username, u.email
FROM orders o
JOIN users u ON o.user_id = u.user_id
WHERE o.status = 'completed'
  AND o.created_at >= '2024-01-01'
  AND u.email LIKE '%@gmail.com'
ORDER BY o.created_at DESC
LIMIT 10;
```

개선된 계획:
```sql
Limit  (cost=0.85..234.56 rows=10 width=150)
       (actual time=0.234..2.345 rows=10 loops=1)
  ->  Nested Loop  (cost=0.85..11234.56 rows=500 width=150)
                   (actual time=0.232..2.340 rows=10 loops=1)
        ->  Index Scan using idx_orders_status_created on orders o
              (cost=0.42..5000.00 rows=1000 width=128)
              (actual time=0.123..1.234 rows=20 loops=1)
              Index Cond: ((status = 'completed') AND (created_at >= '2024-01-01'))
        ->  Index Scan using users_pkey on users u
              (cost=0.42..6.23 rows=1 width=50)
              (actual time=0.045..0.045 rows=0 loops=20)
              Index Cond: (user_id = o.user_id)
              Filter: (email LIKE '%@gmail.com')
              Rows Removed by Filter: 1
  Buffers: shared hit=67
Planning Time: 0.567 ms
Execution Time: 2.456 ms
```

개선 효과:
- 234.987ms → 2.456ms (약 95배 개선)
- Seq Scan → Index Scan
- Buffers: shared hit=67 (모두 메모리에서 처리)

### 실습 3: Covering Index

#### Step 1: 자주 조회하는 컬럼 포함
```sql
-- order_id, total_amount도 인덱스에 포함 (INCLUDE)
CREATE INDEX idx_orders_status_created_covering
ON orders(status, created_at DESC)
INCLUDE (order_id, total_amount, user_id);

-- PostgreSQL 11+에서 INCLUDE 지원
-- 인덱스 크기는 커지지만 테이블 접근 불필요
```

#### Step 2: Index Only Scan 확인
```sql
-- VACUUM으로 Visibility Map 생성 필요
VACUUM ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT o.order_id, o.total_amount, u.username
FROM orders o
JOIN users u ON o.user_id = u.user_id
WHERE o.status = 'completed'
  AND o.created_at >= '2024-01-01'
ORDER BY o.created_at DESC
LIMIT 10;
```

결과:
```sql
Nested Loop  (cost=0.85..123.45 rows=10 width=150)
             (actual time=0.123..0.890 rows=10 loops=1)
  ->  Index Only Scan using idx_orders_status_created_covering on orders o
        (cost=0.42..45.67 rows=10 width=20)
        (actual time=0.100..0.456 rows=10 loops=1)
        Index Cond: ((status = 'completed') AND (created_at >= '2024-01-01'))
        Heap Fetches: 0  -- 테이블 접근 0회
  ->  Index Scan using users_pkey on users u
        (cost=0.42..7.78 rows=1 width=50)
        (actual time=0.034..0.034 rows=1 loops=10)
        Index Cond: (user_id = o.user_id)
  Buffers: shared hit=34
Execution Time: 1.012 ms
```

### 실습 4: 병렬 쿼리

#### Step 1: 대용량 집계
```sql
-- 병렬 처리 가능 설정 확인
SHOW max_parallel_workers_per_gather;  -- 2 이상
SHOW min_parallel_table_scan_size;     -- 8MB

-- 월별 매출 집계
EXPLAIN (ANALYZE, BUFFERS)
SELECT
  DATE_TRUNC('month', created_at) AS month,
  COUNT(*) AS order_count,
  SUM(total_amount) AS total_sales,
  AVG(total_amount) AS avg_sales
FROM orders
WHERE created_at >= '2023-01-01'
GROUP BY DATE_TRUNC('month', created_at)
ORDER BY month;
```

병렬 계획:
```sql
Sort  (cost=12345.67..12345.78 rows=12 width=48)
      (actual time=145.678..145.690 rows=12 loops=1)
  Sort Key: (date_trunc('month', created_at))
  Sort Method: quicksort  Memory: 25kB
  ->  Finalize GroupAggregate  (cost=12000.00..12345.45 rows=12 width=48)
                                (actual time=145.456..145.670 rows=12 loops=1)
        Group Key: (date_trunc('month', created_at))
        ->  Gather Merge  (cost=12000.00..12345.20 rows=24 width=48)
                          (actual time=145.234..145.650 rows=36 loops=1)
              Workers Planned: 2
              Workers Launched: 2
              ->  Partial GroupAggregate  (cost=11000.00..11345.00 rows=12 width=48)
                                          (actual time=142.123..142.456 rows=12 loops=3)
                    Group Key: (date_trunc('month', created_at))
                    ->  Sort  (cost=11000.00..11100.00 rows=20833 width=16)
                              (actual time=140.234..141.123 rows=16667 loops=3)
                          Sort Key: (date_trunc('month', created_at))
                          Sort Method: external merge  Disk: 2048kB
                          Worker 0:  Sort Method: external merge  Disk: 1920kB
                          Worker 1:  Sort Method: external merge  Disk: 2112kB
                          ->  Parallel Seq Scan on orders
                                (cost=0.00..8000.00 rows=20833 width=16)
                                (actual time=0.123..50.234 rows=16667 loops=3)
                                Filter: (created_at >= '2023-01-01')
                                Rows Removed by Filter: 3333
  Buffers: shared hit=5000, temp read=2048 written=2048
Planning Time: 0.345 ms
Execution Time: 146.012 ms
```

해석:
- 2개 Worker 사용 (총 3개 프로세스)
- 각 Worker가 1/3씩 처리 (16,667행)
- Gather Merge로 정렬된 결과 병합

#### Step 2: 병렬도 조정
```sql
-- 쿼리별 병렬도 제어
SET max_parallel_workers_per_gather = 4;

-- 테이블별 기본 병렬도
ALTER TABLE orders SET (parallel_workers = 4);

-- 재실행하여 4개 Worker 사용 확인
EXPLAIN (ANALYZE, BUFFERS)
SELECT
  DATE_TRUNC('month', created_at) AS month,
  COUNT(*) AS order_count,
  SUM(total_amount) AS total_sales
FROM orders
WHERE created_at >= '2023-01-01'
GROUP BY DATE_TRUNC('month', created_at);
```

### 실습 5: 통계 분석

#### Step 1: 통계 정보 확인
```sql
-- orders.status 통계
SELECT
  tablename,
  attname,
  n_distinct,
  most_common_vals,
  most_common_freqs,
  correlation
FROM pg_stats
WHERE tablename = 'orders'
  AND attname IN ('status', 'created_at', 'user_id');
```

#### Step 2: 통계 상세도 조정
```sql
-- status는 카디널리티가 낮으므로 기본 통계로 충분
-- user_id는 높으므로 상세도 증가
ALTER TABLE orders ALTER COLUMN user_id SET STATISTICS 1000;

-- 통계 재수집
ANALYZE orders;

-- 히스토그램 확인
SELECT
  attname,
  array_length(histogram_bounds, 1) as histogram_bins
FROM pg_stats
WHERE tablename = 'orders' AND attname = 'user_id';
-- 기본: 100 bins, 상세도 1000 설정 시 더 정교한 히스토그램
```

#### Step 3: 통계 기반 추정 검증
```sql
-- 플래너 추정 vs 실제
EXPLAIN ANALYZE
SELECT * FROM orders WHERE user_id BETWEEN 1000 AND 1100;

-- 출력에서 확인:
-- rows=50 (플래너 추정)
-- actual rows=48 (실제)
-- 추정이 정확하면 올바른 조인 방식 선택
```

### 실습 6: 복잡한 쿼리 최적화

#### Step 1: 초기 쿼리
```sql
-- 카테고리별 상위 제품 (서브쿼리 사용)
SELECT
  c.name AS category_name,
  p.name AS product_name,
  COUNT(oi.order_item_id) AS order_count,
  SUM(oi.quantity * pv.price) AS total_revenue
FROM categories c
JOIN products p ON c.category_id = p.category_id
JOIN product_variants pv ON p.product_id = pv.product_id
JOIN order_items oi ON pv.variant_id = oi.variant_id
JOIN orders o ON oi.order_id = o.order_id
WHERE o.status = 'completed'
  AND o.created_at >= '2024-01-01'
GROUP BY c.category_id, c.name, p.product_id, p.name
HAVING COUNT(oi.order_item_id) >= 10
ORDER BY total_revenue DESC
LIMIT 20;
```

#### Step 2: 실행 계획 분석
```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
-- 위 쿼리 실행

-- 주의 깊게 볼 점:
-- 1. 조인 순서가 적절한가?
-- 2. 인덱스가 사용되는가?
-- 3. 필터가 일찍 적용되는가?
-- 4. 메모리 부족으로 디스크 사용하는가?
```

#### Step 3: CTE로 리팩토링 (PostgreSQL 17)
```sql
-- CTE로 가독성 향상, v17에서 자동 최적화
WITH completed_orders AS (
  SELECT order_id, created_at
  FROM orders
  WHERE status = 'completed'
    AND created_at >= '2024-01-01'
),
order_revenues AS (
  SELECT
    oi.variant_id,
    COUNT(*) AS order_count,
    SUM(oi.quantity * pv.price) AS revenue
  FROM order_items oi
  JOIN completed_orders co ON oi.order_id = co.order_id
  JOIN product_variants pv ON oi.variant_id = pv.variant_id
  GROUP BY oi.variant_id
  HAVING COUNT(*) >= 10
)
SELECT
  c.name AS category_name,
  p.name AS product_name,
  or.order_count,
  or.revenue AS total_revenue
FROM order_revenues or
JOIN product_variants pv ON or.variant_id = pv.variant_id
JOIN products p ON pv.product_id = p.product_id
JOIN categories c ON p.category_id = c.category_id
ORDER BY or.revenue DESC
LIMIT 20;

-- PostgreSQL 17: CTE가 적절히 인라인되어 최적화됨
```

#### Step 4: 필요한 인덱스 추가
```sql
CREATE INDEX idx_orders_status_created ON orders(status, created_at);
CREATE INDEX idx_order_items_order_id ON order_items(order_id);
CREATE INDEX idx_order_items_variant_id ON order_items(variant_id);
CREATE INDEX idx_product_variants_product_id ON product_variants(product_id);
CREATE INDEX idx_products_category_id ON products(category_id);

ANALYZE orders;
ANALYZE order_items;
ANALYZE product_variants;
ANALYZE products;
ANALYZE categories;
```

### 실습 7: JIT 컴파일 테스트

#### Step 1: JIT 비활성화 상태
```sql
SET jit = off;

EXPLAIN (ANALYZE, BUFFERS)
SELECT
  user_id,
  COUNT(*) FILTER (WHERE status = 'completed') AS completed_count,
  COUNT(*) FILTER (WHERE status = 'pending') AS pending_count,
  SUM(total_amount) FILTER (WHERE status = 'completed') AS completed_amount,
  AVG(total_amount) FILTER (WHERE status = 'completed') AS avg_amount,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_amount) AS median_amount
FROM orders
WHERE created_at >= '2023-01-01'
GROUP BY user_id
HAVING COUNT(*) >= 5;
```

#### Step 2: JIT 활성화
```sql
SET jit = on;
SET jit_above_cost = 100000;

-- 동일 쿼리 재실행
EXPLAIN (ANALYZE, BUFFERS)
SELECT
  user_id,
  COUNT(*) FILTER (WHERE status = 'completed') AS completed_count,
  COUNT(*) FILTER (WHERE status = 'pending') AS pending_count,
  SUM(total_amount) FILTER (WHERE status = 'completed') AS completed_amount,
  AVG(total_amount) FILTER (WHERE status = 'completed') AS avg_amount,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_amount) AS median_amount
FROM orders
WHERE created_at >= '2023-01-01'
GROUP BY user_id
HAVING COUNT(*) >= 5;
```

JIT 출력:
```
JIT:
  Functions: 24
  Options: Inlining true, Optimization true, Expressions true, Deforming true
  Timing: Generation 2.345 ms, Inlining 3.456 ms, Optimization 8.901 ms, Emission 4.567 ms, Total 19.269 ms
Execution Time: 567.890 ms (JIT off: 620.123 ms)
```

효과:
- 복잡한 표현식이 많을수록 효과적
- JIT 컴파일 시간이 있으므로 단순 쿼리는 오히려 느릴 수 있음

## 직접 확인해보기

### 1. 실제 버퍼 사용량 추적
```sql
-- pg_buffercache 확장 설치
CREATE EXTENSION IF NOT EXISTS pg_buffercache;

-- 쿼리 실행 전 버퍼 상태
SELECT COUNT(*) FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('orders'::regclass);

-- 쿼리 실행
SELECT * FROM orders WHERE created_at >= '2024-01-01';

-- 쿼리 실행 후 버퍼 상태
SELECT COUNT(*) FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('orders'::regclass);
```

### 2. 쿼리 플래너 설정 실험
```sql
-- 인덱스 스캔 비용 조정
SET random_page_cost = 1.1;  -- SSD 환경
-- 또는
SET random_page_cost = 4.0;  -- HDD 환경

-- 실행 계획 변화 확인
EXPLAIN SELECT * FROM orders WHERE user_id = 1000;

-- 조인 방식 강제
SET enable_hashjoin = off;
SET enable_mergejoin = off;
-- Nested Loop만 사용

EXPLAIN SELECT * FROM orders o JOIN users u ON o.user_id = u.user_id;
```

### 3. 통계 부정확성 시뮬레이션
```sql
-- 통계 없이 쿼리
DELETE FROM pg_statistic WHERE starelid = 'orders'::regclass;

EXPLAIN SELECT * FROM orders WHERE status = 'completed';
-- rows 추정이 부정확함

-- 통계 복구
ANALYZE orders;

EXPLAIN SELECT * FROM orders WHERE status = 'completed';
-- rows 추정이 정확해짐
```

### 4. 병렬 쿼리 스케일링 테스트
```bash
# psql에서 실행
\timing on

-- Worker 0개
SET max_parallel_workers_per_gather = 0;
SELECT COUNT(*), AVG(total_amount) FROM orders;
-- Time: 500 ms

-- Worker 2개
SET max_parallel_workers_per_gather = 2;
SELECT COUNT(*), AVG(total_amount) FROM orders;
-- Time: 280 ms

-- Worker 4개
SET max_parallel_workers_per_gather = 4;
SELECT COUNT(*), AVG(total_amount) FROM orders;
-- Time: 180 ms

-- Worker 8개
SET max_parallel_workers_per_gather = 8;
SELECT COUNT(*), AVG(total_amount) FROM orders;
-- Time: 140 ms (선형 확장 안 됨, 오버헤드 증가)
```

### 5. 인덱스 선택도 실험
```sql
-- 선택도에 따른 스캔 방식 변화
-- 높은 선택도 (1%)
EXPLAIN ANALYZE SELECT * FROM orders WHERE user_id = 1;
-- Index Scan 사용

-- 중간 선택도 (10%)
EXPLAIN ANALYZE SELECT * FROM orders WHERE status = 'completed';
-- Index Scan 또는 Bitmap Scan

-- 낮은 선택도 (50%)
EXPLAIN ANALYZE SELECT * FROM orders WHERE total_amount > 50;
-- Seq Scan 사용

-- 매우 낮은 선택도 (90%)
EXPLAIN ANALYZE SELECT * FROM orders WHERE total_amount > 10;
-- Seq Scan 확실
```

### 6. EXPLAIN 출력 비교 도구
```sql
-- auto_explain 확장으로 느린 쿼리 자동 로깅
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 100;  -- 100ms 이상 쿼리
SET auto_explain.log_analyze = true;
SET auto_explain.log_buffers = true;

-- 이제 느린 쿼리는 자동으로 로그에 기록됨
-- PostgreSQL 로그 파일 확인
```

### 7. 벤치마크 파일 참조
```sql
-- benchmarks/07-query-optimization.md 파일 확인
-- 다양한 최적화 기법의 전후 비교 수치
-- 실제 운영 환경에서의 측정 결과
```

## 실무 팁

### 1. EXPLAIN 읽기 순서
1. **전체 실행 시간** 확인 (Execution Time)
2. **가장 비용이 큰 노드** 찾기 (cost가 높거나 actual time이 긴 노드)
3. **Rows Removed by Filter** 확인 (높으면 인덱스 필요)
4. **Seq Scan** 찾기 (대형 테이블은 의심)
5. **Buffers** 확인 (shared read가 많으면 캐시 미스)
6. **예측 vs 실제** 비교 (차이가 크면 통계 문제)

### 2. 자주 하는 실수
```sql
-- ❌ 인덱스 컬럼에 함수 사용
SELECT * FROM orders WHERE DATE(created_at) = '2024-01-01';
-- 인덱스 사용 불가

-- ✅ 범위 조건으로 변경
SELECT * FROM orders
WHERE created_at >= '2024-01-01'
  AND created_at < '2024-01-02';

-- ❌ OR 조건으로 인덱스 분산
SELECT * FROM orders WHERE user_id = 1 OR status = 'completed';
-- 여러 인덱스 스캔 또는 Seq Scan

-- ✅ UNION으로 분리 (필요시)
SELECT * FROM orders WHERE user_id = 1
UNION
SELECT * FROM orders WHERE status = 'completed' AND user_id IS DISTINCT FROM 1;

-- ❌ SELECT *로 불필요한 컬럼 조회
SELECT * FROM orders WHERE user_id = 1;
-- Index Only Scan 불가능

-- ✅ 필요한 컬럼만 선택
SELECT order_id, created_at FROM orders WHERE user_id = 1;
-- Index Only Scan 가능 (적절한 인덱스 시)
```

### 3. 통계 관리
```sql
-- 정기적인 ANALYZE (autovacuum이 처리하지만 확인 필요)
SELECT schemaname, tablename, last_analyze, last_autoanalyze,
       n_mod_since_analyze
FROM pg_stat_user_tables
WHERE n_mod_since_analyze > 10000;
-- n_mod_since_analyze가 크면 ANALYZE 실행

-- 중요 테이블은 수동 ANALYZE
ANALYZE orders;

-- 대량 INSERT/UPDATE 후 즉시 ANALYZE
INSERT INTO orders SELECT ... FROM source_table;
ANALYZE orders;
```

### 4. 파라미터 튜닝 우선순위
```sql
-- 1. shared_buffers (메모리의 25%)
ALTER SYSTEM SET shared_buffers = '8GB';

-- 2. effective_cache_size (메모리의 50-75%)
ALTER SYSTEM SET effective_cache_size = '24GB';

-- 3. work_mem (정렬/해시 작업, 동시 접속 고려)
-- 전역 설정은 낮게, 필요시 세션별로 증가
ALTER SYSTEM SET work_mem = '64MB';
-- 특정 쿼리만
SET work_mem = '256MB';
SELECT ...;

-- 4. random_page_cost (SSD는 낮게)
ALTER SYSTEM SET random_page_cost = 1.1;

-- 5. 병렬 쿼리
ALTER SYSTEM SET max_parallel_workers_per_gather = 4;
ALTER SYSTEM SET max_parallel_workers = 8;

SELECT pg_reload_conf();
```

### 5. 모니터링 쿼리
```sql
-- 현재 실행 중인 느린 쿼리
SELECT pid, now() - query_start AS duration, state, query
FROM pg_stat_activity
WHERE state != 'idle'
  AND now() - query_start > interval '5 seconds'
ORDER BY duration DESC;

-- 테이블별 통계
SELECT
  schemaname,
  tablename,
  seq_scan,                           -- 순차 스캔 횟수
  seq_tup_read,                       -- 순차 스캔 행 수
  idx_scan,                           -- 인덱스 스캔 횟수
  idx_tup_fetch,                      -- 인덱스로 가져온 행 수
  n_tup_ins + n_tup_upd + n_tup_del AS modifications
FROM pg_stat_user_tables
ORDER BY seq_scan DESC;
-- seq_scan이 높고 idx_scan이 낮으면 인덱스 필요

-- 인덱스 사용률
SELECT
  schemaname,
  tablename,
  indexname,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch,
  pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC;
-- idx_scan이 0이거나 매우 낮으면 불필요한 인덱스
```

### 6. 실행 계획 캐시
```sql
-- Prepared Statement로 플랜 재사용
PREPARE user_orders (int) AS
SELECT * FROM orders WHERE user_id = $1;

EXECUTE user_orders(1000);
EXECUTE user_orders(2000);

-- 플랜 캐시 확인
SELECT * FROM pg_prepared_statements;

-- 캐시 무효화 (필요시)
DEALLOCATE user_orders;
```

### 7. PostgreSQL 17 활용
```sql
-- CTE 최적화 활용
WITH recent_users AS (
  SELECT user_id FROM users WHERE created_at >= '2024-01-01'
)
SELECT o.*
FROM orders o
WHERE o.user_id IN (SELECT user_id FROM recent_users);
-- v17: CTE가 인라인되어 더 나은 조인 전략 선택

-- GROUP BY 자동 최적화
EXPLAIN SELECT status, payment_method, COUNT(*)
FROM orders
GROUP BY status, payment_method;
-- v17: 카디널리티 낮은 컬럼부터 자동 정렬

-- Incremental Backup으로 시스템 부하 감소
-- 쿼리 성능에 간접적 영향
```

### 8. 개발 단계별 체크리스트

#### 개발 단계
- [ ] SELECT *를 피하고 필요한 컬럼만 선택
- [ ] WHERE 절에 인덱스 컬럼 사용
- [ ] 함수를 인덱스 컬럼에 적용하지 않기
- [ ] LIMIT 사용으로 불필요한 데이터 제한

#### 테스트 단계
- [ ] EXPLAIN ANALYZE로 실행 계획 확인
- [ ] 예상 rows vs 실제 rows 비교
- [ ] Seq Scan이 적절한지 검토
- [ ] 인덱스가 사용되는지 확인

#### 배포 전
- [ ] 프로덕션 데이터 크기로 테스트
- [ ] 통계 정보 최신 상태 확인
- [ ] 인덱스 생성 후 ANALYZE 실행
- [ ] 동시 접속 환경에서 부하 테스트

#### 운영 단계
- [ ] 느린 쿼리 로그 모니터링
- [ ] 주기적인 VACUUM/ANALYZE
- [ ] 인덱스 사용률 점검
- [ ] 파라미터 튜닝 지속

## 참고 링크

### 공식 문서
- [PostgreSQL 17 Documentation - Performance Tips](https://www.postgresql.org/docs/17/performance-tips.html)
- [Chapter 14. Performance Tips](https://www.postgresql.org/docs/17/performance-tips.html)
- [Chapter 15. Parallel Query](https://www.postgresql.org/docs/17/parallel-query.html)
- [EXPLAIN Documentation](https://www.postgresql.org/docs/17/sql-explain.html)
- [Using EXPLAIN](https://www.postgresql.org/docs/17/using-explain.html)
- [Planner Cost Constants](https://www.postgresql.org/docs/17/runtime-config-query.html#RUNTIME-CONFIG-QUERY-CONSTANTS)

### PostgreSQL 17 릴리스 노트
- [PostgreSQL 17 Release Notes - Performance](https://www.postgresql.org/docs/17/release-17.html#RELEASE-17-PERFORMANCE)
- CTE 최적화 개선
- GROUP BY 성능 향상
- Incremental Backup

### 심화 학습
- [The Internals of PostgreSQL - Query Processing](http://www.interdb.jp/pg/pgsql03.html)
- [Depesz's explain.depesz.com](https://explain.depesz.com/) - EXPLAIN 시각화 도구
- [PEV2 - Postgres EXPLAIN Visualizer](https://dalibo.github.io/pev2/)
- [pg_stat_statements](https://www.postgresql.org/docs/17/pgstatstatements.html) - 쿼리 통계 수집

### 관련 노트
- `03-indexing.md`: 인덱스 전략
- `04-partitioning.md`: 파티셔닝으로 대용량 데이터 관리
- `05-monitoring.md`: 성능 모니터링
- `benchmarks/07-query-optimization.md`: 최적화 벤치마크 결과

### 도구
- pgAdmin - GUI에서 EXPLAIN 시각화
- DataGrip - JetBrains IDE, EXPLAIN 분석
- pgBadger - 로그 분석 도구
- pg_stat_monitor - Percona의 향상된 통계 도구

---

**다음 노트**: `08-data-modeling.md` - 데이터 모델링과 스키마 설계
**이전 노트**: `06-transaction-concurrency.md` - 트랜잭션과 동시성 제어
