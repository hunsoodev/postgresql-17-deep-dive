# 파티셔닝과 대용량 데이터

## 한줄 요약
테이블 파티셔닝은 대용량 테이블을 논리적으로는 하나의 테이블로 유지하면서 물리적으로는 여러 개의 작은 파티션으로 분할하여 쿼리 성능, 유지보수성, 그리고 데이터 관리 효율성을 극대화하는 기술입니다.

## 왜 알아야 하는가

### 1. 쿼리 성능 향상
- **파티션 프루닝(Partition Pruning)**: WHERE 절 조건에 따라 불필요한 파티션을 스캔하지 않음
- **병렬 처리**: 각 파티션을 독립적으로 병렬 스캔 가능
- **인덱스 크기 감소**: 파티션별 인덱스는 전체 테이블 인덱스보다 작음

### 2. 데이터 관리 효율성
- **빠른 데이터 삭제**: DROP PARTITION으로 즉시 삭제 (DELETE + VACUUM 불필요)
- **선택적 백업**: 중요한 파티션만 백업 가능
- **데이터 아카이빙**: 오래된 파티션을 저렴한 스토리지로 이동

### 3. 유지보수성
- **개별 파티션 유지보수**: VACUUM, ANALYZE, REINDEX를 파티션별로 수행
- **테이블 잠금 최소화**: 파티션 단위로 작업하여 영향 범위 축소
- **용량 관리**: 파티션별 크기 모니터링 및 관리

### 4. 확장성
- **수평 확장**: 파티션을 서로 다른 테이블스페이스(디스크)에 배치
- **데이터 분산**: 핫 데이터와 콜드 데이터를 다른 스토리지에 분리
- **미래 확장 대비**: 파티션 추가/삭제가 용이

## 핵심 개념

### 1. Declarative Partitioning 개요

PostgreSQL 10부터 도입된 선언적 파티셔닝은 파티션 테이블을 자동으로 관리합니다.

**파티셔닝 아키텍처**:
```
부모 테이블 (Partitioned Table)
    ├── 파티션 1 (Partition)
    ├── 파티션 2 (Partition)
    └── 파티션 3 (Partition)
```

**특징**:
- 부모 테이블에 직접 데이터 저장 불가 (파티션으로 라우팅됨)
- 자동 라우팅: INSERT 시 올바른 파티션으로 자동 삽입
- 제약조건 상속: 파티션은 부모의 제약조건 상속
- 인덱스 상속: 부모 테이블에 인덱스 생성 시 모든 파티션에 자동 생성

### 2. Range Partitioning (범위 파티셔닝)

시간, 날짜, 숫자 범위로 파티션을 나눕니다. 가장 일반적인 파티셔닝 방식입니다.

```sql
-- 이벤트 로그 테이블 (월별 파티셔닝)
CREATE TABLE event_logs (
    log_id BIGSERIAL,
    event_type TEXT NOT NULL,
    user_id INTEGER,
    event_data JSONB,
    created_at TIMESTAMP NOT NULL,
    PRIMARY KEY (log_id, created_at)  -- 파티션 키 포함 필수
) PARTITION BY RANGE (created_at);

-- 2024년 1월 파티션
CREATE TABLE event_logs_2024_01 PARTITION OF event_logs
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

-- 2024년 2월 파티션
CREATE TABLE event_logs_2024_02 PARTITION OF event_logs
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

-- 2024년 3월 파티션
CREATE TABLE event_logs_2024_03 PARTITION OF event_logs
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');

-- 기본 파티션 (범위에 속하지 않는 데이터)
CREATE TABLE event_logs_default PARTITION OF event_logs DEFAULT;
```

**Range 파티셔닝 활용 사례**:
- 시계열 데이터 (로그, 이벤트, 센서 데이터)
- 날짜별 주문, 거래 내역
- 연도별 아카이브 데이터

### 3. List Partitioning (리스트 파티셔닝)

특정 값의 목록으로 파티션을 나눕니다.

```sql
-- 지역별 사용자 테이블
CREATE TABLE users_by_region (
    user_id SERIAL,
    username TEXT NOT NULL,
    email TEXT NOT NULL,
    region TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, region)  -- 파티션 키 포함
) PARTITION BY LIST (region);

-- 서울 지역 파티션
CREATE TABLE users_seoul PARTITION OF users_by_region
    FOR VALUES IN ('서울', 'Seoul', 'SEOUL');

-- 부산 지역 파티션
CREATE TABLE users_busan PARTITION OF users_by_region
    FOR VALUES IN ('부산', 'Busan', 'BUSAN');

-- 기타 지역 파티션
CREATE TABLE users_other PARTITION OF users_by_region
    FOR VALUES IN ('대구', '인천', '광주', '대전', '울산', '세종');

-- 기본 파티션
CREATE TABLE users_default PARTITION OF users_by_region DEFAULT;
```

**List 파티셔닝 활용 사례**:
- 국가/지역별 데이터
- 카테고리별 상품
- 상태별 주문 (pending, completed, cancelled)

### 4. Hash Partitioning (해시 파티셔닝)

해시 함수를 사용하여 데이터를 균등하게 분산합니다.

```sql
-- 사용자 테이블 (해시 파티셔닝)
CREATE TABLE users_hash (
    user_id SERIAL,
    username TEXT NOT NULL,
    email TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id)
) PARTITION BY HASH (user_id);

-- 4개의 해시 파티션 생성
CREATE TABLE users_hash_0 PARTITION OF users_hash
    FOR VALUES WITH (MODULUS 4, REMAINDER 0);

CREATE TABLE users_hash_1 PARTITION OF users_hash
    FOR VALUES WITH (MODULUS 4, REMAINDER 1);

CREATE TABLE users_hash_2 PARTITION OF users_hash
    FOR VALUES WITH (MODULUS 4, REMAINDER 2);

CREATE TABLE users_hash_3 PARTITION OF users_hash
    FOR VALUES WITH (MODULUS 4, REMAINDER 3);
```

**Hash 파티셔닝 활용 사례**:
- 데이터를 균등하게 분산해야 할 때
- 특정 범위나 값으로 나누기 어려운 경우
- 병렬 처리를 위한 데이터 분산

**해시 파티셔닝 주의사항**:
- 파티션 프루닝이 제한적 (정확한 키 값으로만 프루닝 가능)
- 파티션 수 변경 시 데이터 재분배 필요

### 5. Sub-partitioning (다중 파티셔닝)

파티션을 다시 파티셔닝하여 2단계 이상의 파티션 구조를 만듭니다.

```sql
-- 주문 테이블 (날짜 + 지역 다중 파티셔닝)
CREATE TABLE orders_partitioned (
    order_id BIGSERIAL,
    user_id INTEGER NOT NULL,
    region TEXT NOT NULL,
    total_amount NUMERIC(12,2),
    created_at DATE NOT NULL,
    PRIMARY KEY (order_id, created_at, region)
) PARTITION BY RANGE (created_at);

-- 2024년 1월 파티션 (다시 지역으로 서브파티셔닝)
CREATE TABLE orders_2024_01 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01')
    PARTITION BY LIST (region);

CREATE TABLE orders_2024_01_seoul PARTITION OF orders_2024_01
    FOR VALUES IN ('서울');

CREATE TABLE orders_2024_01_busan PARTITION OF orders_2024_01
    FOR VALUES IN ('부산');

CREATE TABLE orders_2024_01_other PARTITION OF orders_2024_01 DEFAULT;

-- 2024년 2월 파티션
CREATE TABLE orders_2024_02 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01')
    PARTITION BY LIST (region);

CREATE TABLE orders_2024_02_seoul PARTITION OF orders_2024_02
    FOR VALUES IN ('서울');

CREATE TABLE orders_2024_02_busan PARTITION OF orders_2024_02
    FOR VALUES IN ('부산');

CREATE TABLE orders_2024_02_other PARTITION OF orders_2024_02 DEFAULT;
```

**Sub-partitioning 활용 사례**:
- 시간 + 지역 복합 파티셔닝
- 카테고리 + 날짜 복합 파티셔닝
- 대용량 데이터의 세밀한 분할

## OS/파일시스템 관점

### 1. 각 파티션 = 별도 파일

파티션 테이블의 가장 중요한 OS 레벨 특징은 **각 파티션이 별도의 물리적 파일**로 저장된다는 점입니다.

```bash
# PostgreSQL 데이터 디렉토리 확인 (Linux/Mac)
$ ls -lh $PGDATA/base/<database_oid>/

# 파티션 테이블 파일 확인
-rw------- 1 postgres postgres 8.0K event_logs_2024_01  # 1월 파티션
-rw------- 1 postgres postgres 8.0K event_logs_2024_02  # 2월 파티션
-rw------- 1 postgres postgres 8.0K event_logs_2024_03  # 3월 파티션
```

**파일 크기 확인**:
```sql
-- 파티션별 물리적 크기 조회
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_indexes_size(schemaname||'.'||tablename)) AS indexes_size
FROM pg_tables
WHERE tablename LIKE 'event_logs_%'
ORDER BY tablename;
```

### 2. 파티션 프루닝 = 불필요한 파일을 열지 않음

파티션 프루닝은 **쿼리 실행 시 필요한 파티션 파일만 열어보는 최적화**입니다.

```sql
-- 2024년 2월 데이터만 조회
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM event_logs
WHERE created_at >= '2024-02-01'
  AND created_at < '2024-03-01';

/*
QUERY PLAN:
Seq Scan on event_logs_2024_02  (cost=0.00..15.00 rows=500 width=100)
  Filter: (created_at >= '2024-02-01' AND created_at < '2024-03-01')
  Buffers: shared hit=5

→ event_logs_2024_02 파티션만 스캔
→ 다른 파티션 파일(01, 03)은 열지도 않음
→ I/O 대폭 감소
*/
```

**프루닝의 OS 레벨 효과**:
- 파일 open() 시스템 콜 감소
- 디스크 읽기 I/O 감소
- 파일 시스템 캐시 효율 증가
- 버퍼 풀 메모리 절약

### 3. DROP PARTITION = 파일 삭제 (즉시)

파티션 삭제는 일반 DELETE와 완전히 다른 메커니즘입니다.

```sql
-- 일반 DELETE (느림)
DELETE FROM event_logs WHERE created_at < '2024-01-01';
-- 1. 모든 파티션 스캔
-- 2. 해당 행 마킹 (dead tuple)
-- 3. VACUUM 실행 전까지 디스크 공간 차지
-- 4. 인덱스도 업데이트 필요

-- DROP PARTITION (빠름)
DROP TABLE event_logs_2023_12;
-- 1. 메타데이터 업데이트
-- 2. 파일 즉시 삭제
-- 3. 디스크 공간 즉시 회수
-- 4. VACUUM 불필요
```

**성능 비교**:
| 작업 | DELETE | DROP PARTITION |
|------|--------|----------------|
| 실행 시간 | 수십 분 ~ 수 시간 | 수 초 |
| 디스크 I/O | 높음 (전체 스캔) | 낮음 (메타데이터만) |
| 잠금 시간 | 길음 | 짧음 |
| VACUUM 필요 | 필수 | 불필요 |
| 공간 회수 | 지연됨 | 즉시 |

### 4. DELETE vs VACUUM

**일반 테이블에서 DELETE의 문제점**:
```bash
# DELETE 후 디스크 상태 (Linux)
$ du -sh event_logs_table
2.5G    event_logs_table  # 삭제 후에도 크기 유지!

# Dead tuple이 공간 차지
SELECT
    schemaname,
    tablename,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_stat_user_tables
WHERE tablename = 'event_logs_table';

-- live_rows: 1000
-- dead_rows: 999000  ← 삭제된 행들이 공간 차지!
-- size: 2.5GB
```

**VACUUM 실행 후**:
```sql
VACUUM FULL event_logs_table;  -- 테이블 재작성 (느림, 배타 잠금)
-- 또는
VACUUM event_logs_table;       -- Dead tuple 마킹만 (빠름, 공유 잠금)

-- VACUUM FULL 후 크기 확인
$ du -sh event_logs_table
50M     event_logs_table  # 공간 회수됨
```

**DROP PARTITION의 우수성**:
```bash
# 파티션 삭제
DROP TABLE event_logs_2023_12;

# 즉시 파일 삭제 확인
$ ls -lh $PGDATA/base/<database_oid>/ | grep event_logs_2023_12
# (결과 없음 - 파일이 즉시 삭제됨)

# 디스크 공간 즉시 회수
$ df -h /var/lib/postgresql/data
# 2.5GB 공간이 즉시 해제됨
```

### 5. 테이블스페이스: 심볼릭 링크 디스크 분산

테이블스페이스를 사용하여 파티션을 서로 다른 물리적 디스크에 배치할 수 있습니다.

```sql
-- 테이블스페이스 생성 (서로 다른 디스크에)
CREATE TABLESPACE hot_data
    LOCATION '/mnt/nvme_ssd/pg_data';  -- 빠른 SSD

CREATE TABLESPACE warm_data
    LOCATION '/mnt/sata_ssd/pg_data';  -- 일반 SSD

CREATE TABLESPACE cold_data
    LOCATION '/mnt/hdd/pg_data';       -- 저렴한 HDD

-- 최근 데이터는 빠른 디스크에
CREATE TABLE event_logs_2024_03 PARTITION OF event_logs
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01')
    TABLESPACE hot_data;

-- 1개월 전 데이터는 일반 디스크에
CREATE TABLE event_logs_2024_02 PARTITION OF event_logs
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01')
    TABLESPACE warm_data;

-- 오래된 데이터는 저렴한 디스크에
CREATE TABLE event_logs_2023_12 PARTITION OF event_logs
    FOR VALUES FROM ('2023-12-01') TO ('2024-01-01')
    TABLESPACE cold_data;
```

**OS 레벨에서 확인**:
```bash
# 테이블스페이스는 심볼릭 링크로 구현됨
$ ls -l $PGDATA/pg_tblspc/
lrwxrwxrwx 1 postgres postgres hot_data -> /mnt/nvme_ssd/pg_data
lrwxrwxrwx 1 postgres postgres warm_data -> /mnt/sata_ssd/pg_data
lrwxrwxrwx 1 postgres postgres cold_data -> /mnt/hdd/pg_data

# 각 디스크의 파티션 파일 확인
$ ls -lh /mnt/nvme_ssd/pg_data/<tablespace_oid>/<database_oid>/
-rw------- 1 postgres postgres 500M event_logs_2024_03

$ ls -lh /mnt/hdd/pg_data/<tablespace_oid>/<database_oid>/
-rw------- 1 postgres postgres 2.0G event_logs_2023_12
```

**테이블스페이스 활용의 이점**:
- 핫 데이터를 빠른 디스크에 배치하여 성능 향상
- 콜드 데이터를 저렴한 디스크에 배치하여 비용 절감
- 디스크 I/O 분산으로 병목 현상 완화
- 디스크 용량 관리 유연성

## PostgreSQL 17: 부울 파티션 프루닝 개선

PostgreSQL 17에서는 부울(Boolean) 조건에 대한 파티션 프루닝이 크게 개선되었습니다.

### 개선 전 (PostgreSQL 16 이하)

```sql
-- 파티션 테이블
CREATE TABLE orders_by_status (
    order_id BIGSERIAL,
    status TEXT NOT NULL,
    is_completed BOOLEAN NOT NULL,
    created_at TIMESTAMP,
    PRIMARY KEY (order_id, is_completed)
) PARTITION BY LIST (is_completed);

CREATE TABLE orders_completed PARTITION OF orders_by_status
    FOR VALUES IN (TRUE);

CREATE TABLE orders_pending PARTITION OF orders_by_status
    FOR VALUES IN (FALSE);

-- PostgreSQL 16: 부울 조건 프루닝 실패
EXPLAIN SELECT * FROM orders_by_status WHERE is_completed;
/*
Append
  -> Seq Scan on orders_completed
  -> Seq Scan on orders_pending  ← 불필요한 파티션도 스캔!
*/
```

### 개선 후 (PostgreSQL 17)

```sql
-- PostgreSQL 17: 부울 조건 프루닝 성공
EXPLAIN SELECT * FROM orders_by_status WHERE is_completed;
/*
Seq Scan on orders_completed  ← 필요한 파티션만 스캔!
*/

-- 복잡한 부울 표현식도 최적화
EXPLAIN SELECT * FROM orders_by_status WHERE is_completed = TRUE;
EXPLAIN SELECT * FROM orders_by_status WHERE NOT is_completed;
EXPLAIN SELECT * FROM orders_by_status WHERE is_completed IS TRUE;
-- 모두 올바르게 프루닝됨
```

**성능 향상**:
- 불필요한 파티션 스캔 제거
- 쿼리 실행 시간 단축
- I/O 감소

## 대량 데이터 로딩

### 1. COPY 명령 (가장 빠름)

```sql
-- CSV 파일에서 대량 데이터 로딩
COPY event_logs (event_type, user_id, event_data, created_at)
FROM '/tmp/events.csv'
WITH (FORMAT csv, HEADER true);

-- 프로그램 출력을 직접 로딩
COPY event_logs (event_type, user_id, event_data, created_at)
FROM PROGRAM 'gzip -dc /tmp/events.csv.gz'
WITH (FORMAT csv, HEADER true);

-- 표준 입력에서 로딩
\copy event_logs (event_type, user_id, event_data, created_at)
FROM STDIN WITH (FORMAT csv);
```

**COPY 성능 팁**:
- 인덱스 제거 후 COPY, 완료 후 인덱스 재생성
- 트리거 비활성화
- `maintenance_work_mem` 증가
- `checkpoint_timeout` 증가

### 2. PostgreSQL 17: ON_ERROR ignore

PostgreSQL 17에서 추가된 `ON_ERROR` 옵션으로 에러가 있는 행을 무시하고 계속 로딩할 수 있습니다.

```sql
-- PostgreSQL 16 이하: 에러 발생 시 전체 롤백
COPY event_logs FROM '/tmp/events_with_errors.csv' WITH (FORMAT csv);
-- ERROR: invalid input syntax for type integer
-- 전체 작업 실패!

-- PostgreSQL 17: 에러 무시하고 계속
COPY event_logs FROM '/tmp/events_with_errors.csv'
WITH (FORMAT csv, ON_ERROR ignore);
-- NOTICE: 3 rows were skipped due to data type incompatibility
-- COPY 9997  (성공한 행만 삽입)

-- 에러 로그 상세 모드
COPY event_logs FROM '/tmp/events_with_errors.csv'
WITH (
    FORMAT csv,
    ON_ERROR ignore,
    LOG_VERBOSITY verbose  -- PostgreSQL 17: 상세 에러 로그
);
```

**ON_ERROR 옵션**:
- `stop` (기본값): 에러 발생 시 즉시 중단
- `ignore`: 에러 행 건너뛰고 계속
- 대량 데이터 로딩 시 매우 유용

### 3. 대량 INSERT 최적화

```sql
-- 다중 행 INSERT (일반적인 방법)
INSERT INTO event_logs (event_type, user_id, event_data, created_at)
VALUES
    ('login', 1, '{"ip": "1.2.3.4"}', '2024-03-01 10:00:00'),
    ('logout', 1, '{"duration": 3600}', '2024-03-01 11:00:00'),
    -- ... 수천 개의 값
    ('purchase', 2, '{"amount": 50000}', '2024-03-01 12:00:00');

-- 트랜잭션 배치 처리
BEGIN;
-- 인덱스 임시 비활성화는 불가능하므로, 대신 체크 제약조건 비활성화
SET CONSTRAINTS ALL DEFERRED;

-- 대량 INSERT
INSERT INTO event_logs VALUES (...);
-- 수백만 행...

COMMIT;
```

### 4. 병렬 로딩

```bash
# 파티션별로 병렬 로딩 (Bash 스크립트)
#!/bin/bash
for month in 01 02 03 04 05 06 07 08 09 10 11 12; do
    psql -c "COPY event_logs_2024_${month} FROM '/data/events_2024_${month}.csv' WITH CSV" &
done
wait  # 모든 백그라운드 작업 완료 대기
```

## 실습 SQL

### 실습 1: event_logs 월별 파티셔닝

```sql
-- 1. 파티션 테이블 생성
CREATE TABLE event_logs (
    log_id BIGSERIAL,
    event_type TEXT NOT NULL,
    user_id INTEGER,
    product_id INTEGER,
    order_id INTEGER,
    event_data JSONB,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (log_id, created_at)
) PARTITION BY RANGE (created_at);

-- 2. 인덱스 생성 (모든 파티션에 자동 적용)
CREATE INDEX idx_event_logs_user_id ON event_logs (user_id);
CREATE INDEX idx_event_logs_event_type ON event_logs (event_type);
CREATE INDEX idx_event_logs_created_at ON event_logs (created_at);
CREATE INDEX idx_event_logs_event_data ON event_logs USING gin (event_data);

-- 3. 2024년 파티션 생성 (월별)
CREATE TABLE event_logs_2024_01 PARTITION OF event_logs
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE event_logs_2024_02 PARTITION OF event_logs
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

CREATE TABLE event_logs_2024_03 PARTITION OF event_logs
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');

CREATE TABLE event_logs_2024_04 PARTITION OF event_logs
    FOR VALUES FROM ('2024-04-01') TO ('2024-05-01');

CREATE TABLE event_logs_2024_05 PARTITION OF event_logs
    FOR VALUES FROM ('2024-05-01') TO ('2024-06-01');

CREATE TABLE event_logs_2024_06 PARTITION OF event_logs
    FOR VALUES FROM ('2024-06-01') TO ('2024-07-01');

-- 4. 기본 파티션 (범위 밖 데이터)
CREATE TABLE event_logs_default PARTITION OF event_logs DEFAULT;

-- 5. 파티션 자동 생성 함수 (PostgreSQL 17)
CREATE OR REPLACE FUNCTION create_event_logs_partition(target_date DATE)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    partition_name TEXT;
    start_date DATE;
    end_date DATE;
BEGIN
    partition_name := 'event_logs_' || TO_CHAR(target_date, 'YYYY_MM');
    start_date := DATE_TRUNC('month', target_date);
    end_date := start_date + INTERVAL '1 month';

    -- 파티션이 이미 존재하는지 확인
    IF EXISTS (
        SELECT 1 FROM pg_class
        WHERE relname = partition_name
    ) THEN
        RETURN 'Partition already exists: ' || partition_name;
    END IF;

    -- 파티션 생성
    EXECUTE format(
        'CREATE TABLE %I PARTITION OF event_logs FOR VALUES FROM (%L) TO (%L)',
        partition_name,
        start_date,
        end_date
    );

    RETURN 'Created partition: ' || partition_name;
END;
$$;

-- 미래 파티션 미리 생성
SELECT create_event_logs_partition('2024-07-01');
SELECT create_event_logs_partition('2024-08-01');
SELECT create_event_logs_partition('2024-09-01');
```

### 실습 2: 100만 행 로딩

```sql
-- 1. 테스트 데이터 생성 함수
CREATE OR REPLACE FUNCTION generate_event_logs(num_rows INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    i INTEGER;
    event_types TEXT[] := ARRAY['login', 'logout', 'view_product', 'add_to_cart',
                                 'remove_from_cart', 'checkout', 'payment', 'purchase'];
BEGIN
    FOR i IN 1..num_rows LOOP
        INSERT INTO event_logs (
            event_type,
            user_id,
            product_id,
            order_id,
            event_data,
            created_at
        ) VALUES (
            event_types[1 + (random() * 7)::INTEGER],
            1 + (random() * 10000)::INTEGER,
            CASE WHEN random() > 0.5 THEN 1 + (random() * 1000)::INTEGER ELSE NULL END,
            CASE WHEN random() > 0.9 THEN 1 + (random() * 5000)::INTEGER ELSE NULL END,
            jsonb_build_object(
                'session_id', md5(random()::TEXT),
                'referrer', 'https://example.com',
                'duration', (random() * 3600)::INTEGER
            ),
            TIMESTAMP '2024-01-01' + (random() * INTERVAL '180 days')
        );

        -- 진행 상황 표시
        IF i % 10000 = 0 THEN
            RAISE NOTICE 'Inserted % rows', i;
        END IF;
    END LOOP;
END;
$$;

-- 2. 100만 행 생성 (시간 측정)
\timing on
SELECT generate_event_logs(1000000);
\timing off

-- 3. COPY를 사용한 더 빠른 로딩 (CSV 파일로부터)
-- 먼저 CSV 파일 생성
COPY (
    SELECT
        event_types[1 + (random() * 7)::INTEGER] AS event_type,
        1 + (random() * 10000)::INTEGER AS user_id,
        CASE WHEN random() > 0.5 THEN 1 + (random() * 1000)::INTEGER ELSE NULL END AS product_id,
        jsonb_build_object('session_id', md5(random()::TEXT)) AS event_data,
        TIMESTAMP '2024-01-01' + (random() * INTERVAL '180 days') AS created_at
    FROM
        generate_series(1, 1000000),
        (SELECT ARRAY['login', 'logout', 'view_product', 'add_to_cart',
                      'remove_from_cart', 'checkout', 'payment', 'purchase'] AS event_types) et
) TO '/tmp/event_logs.csv' WITH (FORMAT csv, HEADER true);

-- CSV로부터 로딩 (훨씬 빠름)
\timing on
COPY event_logs (event_type, user_id, product_id, event_data, created_at)
FROM '/tmp/event_logs.csv' WITH (FORMAT csv, HEADER true);
\timing off
```

### 실습 3: 파티션 프루닝 확인

```sql
-- 1. 파티션별 데이터 개수 확인
SELECT
    schemaname,
    tablename,
    n_live_tup AS row_count,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size
FROM pg_stat_user_tables
WHERE tablename LIKE 'event_logs_%'
ORDER BY tablename;

-- 2. 파티션 프루닝 확인 (단일 월 조회)
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT COUNT(*)
FROM event_logs
WHERE created_at >= '2024-03-01'
  AND created_at < '2024-04-01';

/*
예상 결과:
Aggregate  (actual time=... rows=1 loops=1)
  ->  Seq Scan on event_logs_2024_03  (actual time=... rows=... loops=1)
        Filter: (created_at >= '2024-03-01' AND created_at < '2024-04-01')
        Buffers: shared hit=...

→ event_logs_2024_03 파티션만 스캔됨!
*/

-- 3. 여러 파티션 걸침 (프루닝 여전히 작동)
EXPLAIN (ANALYZE, BUFFERS)
SELECT event_type, COUNT(*)
FROM event_logs
WHERE created_at >= '2024-02-15'
  AND created_at < '2024-04-15'
GROUP BY event_type;

/*
예상 결과:
HashAggregate
  ->  Append
        ->  Seq Scan on event_logs_2024_02
        ->  Seq Scan on event_logs_2024_03
        ->  Seq Scan on event_logs_2024_04

→ 필요한 3개 파티션만 스캔 (01, 05, 06 등은 제외)
*/

-- 4. 프루닝 없는 쿼리 (모든 파티션 스캔)
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM event_logs
WHERE user_id = 123;

/*
예상 결과:
Aggregate
  ->  Append
        ->  Seq Scan on event_logs_2024_01
        ->  Seq Scan on event_logs_2024_02
        ->  Seq Scan on event_logs_2024_03
        ->  Seq Scan on event_logs_2024_04
        ->  Seq Scan on event_logs_2024_05
        ->  Seq Scan on event_logs_2024_06

→ 모든 파티션 스캔 (created_at 조건 없음)
*/

-- 5. 인덱스 사용 확인
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM event_logs
WHERE created_at >= '2024-03-01'
  AND created_at < '2024-04-01'
  AND user_id = 123;

/*
예상 결과:
Index Scan using event_logs_2024_03_user_id_idx on event_logs_2024_03
  Index Cond: (user_id = 123)
  Filter: (created_at >= '2024-03-01' AND created_at < '2024-04-01')

→ 파티션 프루닝 + 인덱스 스캔
*/
```

### 실습 4: 파티션 관리 작업

```sql
-- 1. 오래된 파티션 분리 (DETACH)
ALTER TABLE event_logs DETACH PARTITION event_logs_2024_01;
-- 이제 event_logs_2024_01은 독립 테이블
-- 쿼리에서는 제외되지만 데이터는 유지됨

-- 2. 분리된 파티션을 아카이브 스키마로 이동
CREATE SCHEMA IF NOT EXISTS archive;
ALTER TABLE event_logs_2024_01 SET SCHEMA archive;

-- 3. 파티션 재연결
ALTER TABLE event_logs ATTACH PARTITION archive.event_logs_2024_01
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

-- 4. 파티션 삭제 (데이터 포함)
DROP TABLE event_logs_2024_01;
-- 또는 분리 후 삭제
ALTER TABLE event_logs DETACH PARTITION event_logs_2024_01;
DROP TABLE event_logs_2024_01;

-- 5. 파티션별 VACUUM 및 ANALYZE
VACUUM ANALYZE event_logs_2024_03;

-- 6. 파티션 통계 갱신
ANALYZE event_logs_2024_03;

-- 7. 파티션 재색인
REINDEX TABLE event_logs_2024_03;
```

## 직접 확인해보기

### 1. 파티션 구조 확인

```sql
-- 파티션 계층 구조 조회
SELECT
    nmsp_parent.nspname AS parent_schema,
    parent.relname AS parent_table,
    nmsp_child.nspname AS child_schema,
    child.relname AS child_partition,
    pg_get_expr(child.relpartbound, child.oid) AS partition_bounds
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child ON pg_inherits.inhrelid = child.oid
JOIN pg_namespace nmsp_parent ON parent.relnamespace = nmsp_parent.oid
JOIN pg_namespace nmsp_child ON child.relnamespace = nmsp_child.oid
WHERE parent.relname = 'event_logs'
ORDER BY child.relname;
```

### 2. 파티션 크기 모니터링

```sql
-- 파티션별 상세 크기 정보
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_indexes_size(schemaname||'.'||tablename)) AS indexes_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) -
                   pg_relation_size(schemaname||'.'||tablename) -
                   pg_indexes_size(schemaname||'.'||tablename)) AS toast_size
FROM pg_tables
WHERE tablename LIKE 'event_logs_%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

### 3. 파티션 프루닝 통계

```sql
-- pg_stat_statements로 파티션 프루닝 효과 확인
SELECT
    query,
    calls,
    total_exec_time,
    mean_exec_time,
    rows
FROM pg_stat_statements
WHERE query LIKE '%event_logs%'
ORDER BY mean_exec_time DESC
LIMIT 10;
```

### 4. 파티션별 행 수 및 통계

```sql
-- 파티션별 데이터 분포
SELECT
    tableoid::regclass AS partition_name,
    COUNT(*) AS row_count,
    MIN(created_at) AS min_date,
    MAX(created_at) AS max_date,
    pg_size_pretty(pg_total_relation_size(tableoid)) AS size
FROM event_logs
GROUP BY tableoid
ORDER BY min_date;
```

## 벤치마크 참조

실제 성능 측정 결과는 `benchmarks/11-partition-pruning.md` 파일을 참조하세요.

**주요 벤치마크 항목**:
1. 파티션 vs 비파티션 테이블 조회 성능
2. 파티션 프루닝 효과 측정
3. DELETE vs DROP PARTITION 시간 비교
4. COPY vs INSERT 로딩 속도 비교
5. 파티션 수에 따른 성능 변화

## 실무 팁

### 1. 파티션 키 선택 기준

**좋은 파티션 키**:
- 쿼리 WHERE 절에 자주 사용되는 컬럼
- 범위로 나눌 수 있는 컬럼 (날짜, 시간, 숫자)
- 데이터 분포가 균등한 컬럼

**나쁜 파티션 키**:
- NULL 값이 많은 컬럼
- 카디널리티가 너무 높거나 낮은 컬럼
- 자주 업데이트되는 컬럼

### 2. 파티션 크기 가이드라인

- **권장 파티션 크기**: 10GB ~ 50GB
- **파티션 수**: 수십 개 ~ 수백 개 (수천 개 이상은 비효율적)
- **너무 작은 파티션**: 관리 오버헤드 증가
- **너무 큰 파티션**: 파티션 프루닝 효과 감소

### 3. 파티션 유지보수 자동화

```sql
-- 매월 자동으로 다음 달 파티션 생성 (cron 작업)
CREATE OR REPLACE FUNCTION auto_create_next_month_partition()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- 다음 달 파티션 생성
    PERFORM create_event_logs_partition(
        DATE_TRUNC('month', CURRENT_DATE + INTERVAL '1 month')
    );

    -- 6개월 이상 오래된 파티션 아카이브
    PERFORM archive_old_partitions(INTERVAL '6 months');
END;
$$;

-- 오래된 파티션 아카이브 함수
CREATE OR REPLACE FUNCTION archive_old_partitions(retention_period INTERVAL)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    partition_rec RECORD;
    cutoff_date DATE;
BEGIN
    cutoff_date := CURRENT_DATE - retention_period;

    FOR partition_rec IN
        SELECT tablename
        FROM pg_tables
        WHERE tablename ~ '^event_logs_\d{4}_\d{2}$'
          AND tablename < 'event_logs_' || TO_CHAR(cutoff_date, 'YYYY_MM')
    LOOP
        -- 파티션 분리
        EXECUTE format('ALTER TABLE event_logs DETACH PARTITION %I', partition_rec.tablename);

        -- 아카이브 스키마로 이동
        EXECUTE format('ALTER TABLE %I SET SCHEMA archive', partition_rec.tablename);

        RAISE NOTICE 'Archived partition: %', partition_rec.tablename;
    END LOOP;
END;
$$;
```

### 4. 파티션 제약조건 최적화

```sql
-- 파티션 제약조건 자동 검증 비활성화 (성능 향상)
-- 데이터가 올바른 파티션에만 들어간다고 확신할 때 사용
ALTER TABLE event_logs_2024_03 SET (
    autovacuum_enabled = true,
    autovacuum_vacuum_scale_factor = 0.05,  -- 더 자주 VACUUM
    autovacuum_analyze_scale_factor = 0.02  -- 더 자주 ANALYZE
);
```

### 5. 파티션 인덱스 전략

```sql
-- 부모 테이블에 인덱스 생성 (모든 파티션에 자동 적용)
CREATE INDEX idx_global ON event_logs (user_id, created_at);

-- 특정 파티션에만 인덱스 생성
CREATE INDEX idx_local ON event_logs_2024_03 (event_type)
    WHERE event_type IN ('purchase', 'payment');  -- 부분 인덱스
```

### 6. 파티션 모니터링

```sql
-- 파티션 상태 모니터링 뷰
CREATE OR REPLACE VIEW v_partition_health AS
SELECT
    schemaname,
    tablename,
    n_live_tup AS rows,
    n_dead_tup AS dead_rows,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_ratio,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_stat_user_tables
WHERE tablename LIKE 'event_logs_%'
ORDER BY tablename;

-- 사용법
SELECT * FROM v_partition_health;
```

## 참고 링크

### 공식 PostgreSQL 17 문서
- [Chapter 5.11: Table Partitioning](https://www.postgresql.org/docs/17/ddl-partitioning.html)
- [Chapter 5.11.1: Overview](https://www.postgresql.org/docs/17/ddl-partitioning.html#DDL-PARTITIONING-OVERVIEW)
- [Chapter 5.11.2: Declarative Partitioning](https://www.postgresql.org/docs/17/ddl-partitioning.html#DDL-PARTITIONING-DECLARATIVE)
- [Chapter 5.11.4: Partition Pruning](https://www.postgresql.org/docs/17/ddl-partitioning.html#DDL-PARTITIONING-PRUNING)
- [COPY Command](https://www.postgresql.org/docs/17/sql-copy.html)
- [CREATE TABLESPACE](https://www.postgresql.org/docs/17/sql-createtablespace.html)

### PostgreSQL 17 릴리스 노트
- [PostgreSQL 17 Release Notes - Partitioning](https://www.postgresql.org/docs/17/release-17.html)
- Boolean Partition Pruning Improvements
- COPY ON_ERROR Option

### 성능 및 모니터링
- [pg_stat_user_tables](https://www.postgresql.org/docs/17/monitoring-stats.html#MONITORING-PG-STAT-ALL-TABLES-VIEW)
- [pg_partitioned_table](https://www.postgresql.org/docs/17/catalog-pg-partitioned-table.html)

### 추가 학습 자료
- PostgreSQL Wiki: Table Partitioning
- PostgreSQL Performance Blog: Partition Pruning
- Best Practices for Partitioning Large Tables
