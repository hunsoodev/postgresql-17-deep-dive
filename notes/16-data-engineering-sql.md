# 데이터 엔지니어링을 위한 PostgreSQL 실전 SQL

## 한줄 요약

데이터 엔지니어링에서 PostgreSQL을 제대로 활용하려면 COPY, Upsert, Window Function, LATERAL JOIN 같은 핵심 패턴을 상황에 맞게 선택하고, PG17의 JSON_TABLE, MERGE RETURNING, ON_ERROR 같은 신기능까지 조합할 수 있어야 합니다.

> 📖 이 노트의 모든 SQL은 PostgreSQL 17 공식 문서 및 커뮤니티 모범 사례를 기반으로 작성되었습니다.
> 각 섹션 하단에 출처를 명시했습니다.

## 실습 환경

```bash
cd docker && docker compose up -d
docker exec -it pg17-lab psql -U labuser -d ecommerce
```

---

## 목차

| # | 주제 | 핵심 상황 |
|---|------|----------|
| 1 | [COPY — 대량 데이터 적재/추출](#1-copy--대량-데이터-적재추출) | 수백만 행 CSV를 빠르게 DB에 넣어야 할 때 |
| 2 | [INSERT ... ON CONFLICT — Upsert](#2-insert--on-conflict--upsert) | "있으면 갱신, 없으면 삽입"이 필요할 때 |
| 3 | [MERGE — 차세대 동기화](#3-merge--차세대-동기화-pg15-returning-pg17) | 소스-타겟 양방향 동기화가 필요할 때 |
| 4 | [CTE — 복잡한 변환 파이프라인](#4-cte--복잡한-변환-파이프라인) | 다단계 ETL을 한 쿼리로 처리할 때 |
| 5 | [Window Function — 분석 쿼리](#5-window-function--분석-쿼리) | 전일 대비, 이동 평균, Top-N이 필요할 때 |
| 6 | [LATERAL JOIN — 그룹별 Top-N](#6-lateral-join--그룹별-top-n) | "사용자별 최근 주문 3건"이 필요할 때 |
| 7 | [JSON/JSONB 처리](#7-jsonjsonb-처리) | 반정형 이벤트 로그를 관계형으로 변환할 때 |
| 8 | [파티셔닝 — 대규모 테이블 관리](#8-파티셔닝--대규모-테이블-관리) | 수억 행 테이블의 적재/삭제/조회를 빠르게 할 때 |
| 9 | [Materialized View — 사전 집계](#9-materialized-view--사전-집계) | 대시보드 쿼리가 너무 느릴 때 |
| 10 | [Temp / Unlogged 테이블 — 스테이징](#10-temp--unlogged-테이블--스테이징) | ETL 중간 결과를 임시 저장할 때 |
| 11 | [generate_series — 시계열 생성과 갭 채우기](#11-generate_series--시계열-생성과-갭-채우기) | 빠진 날짜/시간대를 0으로 채워야 할 때 |
| 12 | [배치 처리 패턴](#12-배치-처리-패턴) | 수백만 행을 안전하게 갱신/삭제할 때 |
| 13 | [EXPLAIN ANALYZE — 쿼리 최적화](#13-explain-analyze--쿼리-최적화) | "이 쿼리 왜 느리지?"를 파악할 때 |
| 14 | [카탈로그 & 통계 쿼리](#14-카탈로그--통계-쿼리) | 테이블 크기, 미사용 인덱스, dead tuple 확인 |
| 15 | [Foreign Data Wrapper — 외부 데이터 연결](#15-foreign-data-wrapper--외부-데이터-연결) | 다른 DB나 CSV를 직접 조회해야 할 때 |
| 16 | [데이터 품질 보장](#16-데이터-품질-보장) | DB 레벨에서 잘못된 데이터를 원천 차단할 때 |

---

## 1. COPY — 대량 데이터 적재/추출

### 언제 쓰는가

- **매일 밤 수백만 행의 CSV/TSV 파일을 DB에 적재**하는 배치 ETL
- **테이블 데이터를 CSV로 추출**하여 S3, GCS 등에 업로드
- **다른 시스템에서 pg_dump 없이** 특정 테이블만 빠르게 이관

> INSERT 문으로 100만 행을 넣으면 수십 분이지만, COPY는 수십 초면 끝납니다.
> COPY는 파서, 플래너, 실행기를 거치지 않고 직접 힙 파일에 쓰기 때문입니다.
> — [PostgreSQL: Populating a Database](https://www.postgresql.org/docs/17/populate.html)

### 기본 문법

```sql
-- CSV 적재 (서버 파일시스템)
COPY orders FROM '/data/orders.csv'
    WITH (FORMAT csv, HEADER true, DELIMITER ',');

-- CSV 추출
COPY (SELECT * FROM orders WHERE created_at >= '2026-01-01')
    TO '/data/orders_2026.csv'
    WITH (FORMAT csv, HEADER true);
```

### 압축 파일 직접 처리 (COPY FROM PROGRAM)

```sql
-- gzip 파일을 실시간 해제하며 적재
COPY orders FROM PROGRAM 'zcat /data/orders.csv.gz'
    WITH (FORMAT csv, HEADER true);

-- S3에서 직접 스트리밍
COPY orders FROM PROGRAM 'aws s3 cp s3://my-bucket/orders.csv -'
    WITH (FORMAT csv, HEADER true);

-- 추출 시 압축
COPY orders TO PROGRAM 'gzip > /data/orders.csv.gz'
    WITH (FORMAT csv, HEADER true);
```

> ⚠️ `COPY ... PROGRAM`은 서버에서 OS 명령을 실행하므로 **superuser 권한**이 필요합니다.

### COPY vs \copy

| 항목 | `COPY` (SQL) | `\copy` (psql 메타 명령) |
|------|-------------|------------------------|
| 파일 위치 | **서버** 파일시스템 | **클라이언트** 파일시스템 |
| 권한 | superuser 필요 (파일 경로) | 일반 사용자 가능 |
| 성능 | 빠름 (네트워크 전송 없음) | 느림 (psql을 통해 전송) |
| 용도 | 서버 로컬 배치 ETL | 개발자 로컬 PC에서 데이터 주고받기 |

```bash
# 클라이언트(내 노트북)에서 파일 적재
\copy orders FROM '/Users/me/orders.csv' WITH (FORMAT csv, HEADER)
```

### 🆕 PG17: ON_ERROR — 오류 행 건너뛰기

```sql
-- 더러운 CSV에서 타입 변환 오류가 있는 행을 건너뛰고 적재
COPY orders FROM '/data/dirty_orders.csv'
    WITH (FORMAT csv, HEADER true, ON_ERROR ignore);
-- NOTICE: 42 rows were skipped due to data type incompatibility

-- 어떤 행이 건너뛰어졌는지 상세 로그
COPY orders FROM '/data/dirty_orders.csv'
    WITH (FORMAT csv, HEADER true, ON_ERROR ignore, LOG_VERBOSITY verbose);
-- NOTICE: skipping row 1847, column "price": invalid input syntax for type numeric: "N/A"
```

> 기존에는 하나의 오류 행 때문에 전체 COPY가 실패했습니다.
> PG17의 `ON_ERROR ignore`는 데이터 품질이 완벽하지 않은 외부 소스를 처리할 때 필수입니다.
> — [PostgreSQL 17: COPY ON_ERROR](https://www.postgresql.org/docs/17/sql-copy.html)

### 대량 적재 성능 최적화 팁

```sql
-- 1. 인덱스 제거 후 적재, 이후 재생성 (인덱스 유지보수 비용 제거)
DROP INDEX IF EXISTS idx_orders_user_id;
COPY orders FROM '/data/orders.csv' WITH (FORMAT csv, HEADER);
CREATE INDEX idx_orders_user_id ON orders(user_id);

-- 2. 트리거 비활성화
ALTER TABLE orders DISABLE TRIGGER ALL;
COPY orders FROM '/data/orders.csv' WITH (FORMAT csv, HEADER);
ALTER TABLE orders ENABLE TRIGGER ALL;

-- 3. FREEZE 옵션 (빈 테이블/TRUNCATE 직후에만 가능)
--    행을 즉시 "frozen" 상태로 만들어 향후 VACUUM 불필요
BEGIN;
TRUNCATE orders;
COPY orders FROM '/data/orders.csv' WITH (FORMAT csv, HEADER, FREEZE);
COMMIT;

-- 4. maintenance_work_mem 증가 (인덱스 재생성 시)
SET maintenance_work_mem = '1GB';
CREATE INDEX idx_orders_created ON orders(created_at);
```

### 실전 시나리오: 일별 ETL 파이프라인

```sql
BEGIN;

-- 1. 스테이징 테이블에 원본 적재
CREATE UNLOGGED TABLE stg_orders (LIKE orders INCLUDING DEFAULTS);
COPY stg_orders FROM PROGRAM 'zcat /data/nightly/orders_20260212.csv.gz'
    WITH (FORMAT csv, HEADER true, ON_ERROR ignore);

-- 2. 프로덕션 테이블에 Upsert
INSERT INTO orders
SELECT * FROM stg_orders
ON CONFLICT (order_id) DO UPDATE
    SET status = EXCLUDED.status,
        updated_at = EXCLUDED.updated_at;

-- 3. 정리
DROP TABLE stg_orders;
COMMIT;
```

---

## 2. INSERT ... ON CONFLICT — Upsert

### 언제 쓰는가

- **"있으면 갱신, 없으면 삽입"** 로직이 필요한 모든 데이터 동기화
- **이벤트 스트림의 중복 제거** (idempotent insert)
- **차원 테이블(Dimension Table)** SCD Type 1 갱신

> INSERT ... ON CONFLICT는 PG9.5에서 도입되었으며, 동시성 문제를 원자적으로 해결합니다.
> 별도의 "SELECT 후 INSERT 또는 UPDATE" 패턴에서 발생하는 레이스 컨디션이 없습니다.
> — [PostgreSQL: INSERT](https://www.postgresql.org/docs/17/sql-insert.html)

### 패턴별 정리

#### DO UPDATE SET — 클래식 Upsert

```sql
-- 상황: 외부 시스템에서 상품 정보가 매일 갱신됨.
-- 새 상품이면 삽입, 기존 상품이면 가격/재고 갱신
INSERT INTO products (sku, name, price, stock, updated_at)
VALUES ('SKU-001', 'Wireless Mouse', 29.99, 150, NOW())
ON CONFLICT (sku)
DO UPDATE SET
    name       = EXCLUDED.name,
    price      = EXCLUDED.price,
    stock      = EXCLUDED.stock,
    updated_at = EXCLUDED.updated_at;

-- EXCLUDED는 "삽입하려던 값"을 담고 있는 가상 테이블입니다
```

#### DO NOTHING — 중복 무시 (Idempotent Insert)

```sql
-- 상황: 이벤트 로그를 카프카에서 컨슈밍하는데, at-least-once 보장이므로
-- 같은 이벤트가 중복 들어올 수 있음 → 조용히 무시
INSERT INTO event_logs (event_id, user_id, event_type, created_at)
VALUES ('evt-abc-123', 1001, 'page_view', '2026-02-12 10:30:00')
ON CONFLICT (event_id) DO NOTHING;
```

#### 조건부 갱신 — 더 최신 데이터만 반영

```sql
-- 상황: CDC(Change Data Capture)로 들어오는 데이터가 순서가 뒤섞일 수 있음
-- → 기존 데이터보다 새로운 경우에만 갱신
INSERT INTO products (sku, name, price, updated_at)
VALUES ('SKU-001', 'Wireless Mouse', 34.99, '2026-02-12 15:00:00')
ON CONFLICT (sku) DO UPDATE SET
    name       = EXCLUDED.name,
    price      = EXCLUDED.price,
    updated_at = EXCLUDED.updated_at
WHERE products.updated_at < EXCLUDED.updated_at;
-- WHERE 조건이 거짓이면 갱신하지 않음 (오래된 데이터 무시)
```

#### 복합 키 Upsert

```sql
-- 상황: 주문 항목 수량이 변경되면 기존 수량에 더함
INSERT INTO order_items (order_id, product_id, quantity, price)
VALUES (1001, 500, 3, 29.99)
ON CONFLICT (order_id, product_id) DO UPDATE SET
    quantity = order_items.quantity + EXCLUDED.quantity;
```

#### RETURNING으로 결과 확인

```sql
-- 상황: 벌크 Upsert 후 어떤 행이 삽입/갱신되었는지 추적
INSERT INTO products (sku, name, price)
SELECT sku, name, price FROM staging_products
ON CONFLICT (sku) DO UPDATE SET
    name  = EXCLUDED.name,
    price = EXCLUDED.price
RETURNING sku, (xmax = 0) AS was_inserted;
-- xmax = 0 이면 새로 삽입, 아니면 갱신
```

### 성능 참고

- ON CONFLICT는 **UNIQUE 인덱스 또는 UNIQUE 제약조건**이 반드시 필요합니다
- DO UPDATE는 충돌 행에 **행 잠금**을 걸므로, 동일 키에 대한 동시 쓰기는 직렬화됩니다
- 벌크 Upsert 시 여러 VALUES를 하나의 INSERT 문에 담는 것이 개별 INSERT보다 훨씬 빠릅니다

---

## 3. MERGE — 차세대 동기화 (PG15+, RETURNING PG17)

### 언제 쓰는가

- **소스 테이블과 타겟 테이블의 양방향 동기화** (데이터 웨어하우스의 차원 테이블 갱신)
- **"소스에 없는 행은 삭제/비활성화"** 로직이 필요할 때 (ON CONFLICT로는 불가능)
- SQL 표준(SQL:2008) 준수가 요구될 때

> `MERGE`는 INSERT, UPDATE, DELETE를 하나의 문장으로 결합합니다.
> PG17에서 `RETURNING` 절과 `merge_action()` 함수가 추가되어 각 행에 어떤 작업이 수행되었는지 확인할 수 있습니다.
> — [PostgreSQL 17: MERGE](https://www.postgresql.org/docs/17/sql-merge.html)

### 전체 패턴

```sql
-- 상황: 매일 공급업체 피드(supplier_feed)로 상품 데이터를 동기화
-- - 가격이 변경된 기존 상품 → 갱신
-- - 새 상품 → 삽입
-- - 공급업체에서 빠진 상품 → "단종" 처리

MERGE INTO products p
USING supplier_feed s ON p.sku = s.sku

-- 매칭 + 변경사항 있음 → 갱신
WHEN MATCHED AND (p.price, p.name) IS DISTINCT FROM (s.price, s.name) THEN
    UPDATE SET
        price = s.price,
        name = s.name,
        stock = s.stock,
        updated_at = NOW()

-- 매칭 + 변경사항 없음 → 재고만 갱신
WHEN MATCHED THEN
    UPDATE SET stock = s.stock, updated_at = NOW()

-- 소스에만 있음 (신규 상품) → 삽입
WHEN NOT MATCHED BY TARGET THEN
    INSERT (sku, name, price, stock, created_at, updated_at)
    VALUES (s.sku, s.name, s.price, s.stock, NOW(), NOW())

-- 타겟에만 있음 (공급업체에서 빠진 상품) → 단종 처리
WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET status = 'discontinued', updated_at = NOW();
```

### 🆕 PG17: RETURNING + merge_action()

```sql
-- 각 행에 어떤 작업이 수행되었는지 확인
MERGE INTO products p
USING staging_products s ON p.sku = s.sku
WHEN MATCHED THEN
    UPDATE SET price = s.price, stock = s.stock
WHEN NOT MATCHED BY TARGET THEN
    INSERT (sku, name, price, stock)
    VALUES (s.sku, s.name, s.price, s.stock)
WHEN NOT MATCHED BY SOURCE AND p.status = 'active' THEN
    DELETE
RETURNING merge_action(), p.sku, p.name, p.price;

-- 결과:
--  merge_action | sku     | name           | price
-- --------------+---------+----------------+-------
--  UPDATE       | SKU-001 | Wireless Mouse | 34.99
--  INSERT       | SKU-099 | New Widget     |  9.99
--  DELETE       | SKU-050 | Old Product    | 19.99
```

### MERGE vs INSERT ... ON CONFLICT 비교

| 항목 | MERGE | INSERT ... ON CONFLICT |
|------|-------|----------------------|
| SQL 표준 | ✅ SQL:2008 | ❌ PostgreSQL 확장 |
| 사용 가능 버전 | PG15+ | PG9.5+ |
| 소스 | 테이블, 서브쿼리, VALUES 모두 가능 | INSERT하려는 VALUES만 |
| 가능한 작업 | INSERT, UPDATE, DELETE | INSERT 또는 UPDATE만 |
| NOT MATCHED BY SOURCE | ✅ (타겟에만 있는 행 처리) | ❌ 불가능 |
| 동시성 안전성 | ⚠️ 동시 INSERT 시 중복 가능 | ✅ UNIQUE 제약으로 원자적 처리 |
| **권장 사용 시나리오** | **배치 동기화, 차원 테이블 갱신** | **실시간 Upsert, 이벤트 중복 제거** |

---

## 4. CTE — 복잡한 변환 파이프라인

### 언제 쓰는가

- **다단계 ETL 변환**을 하나의 SQL 문으로 표현할 때 (가독성 + 원자성)
- **DELETE/UPDATE 결과를 다른 테이블에 INSERT**할 때 (Data-Modifying CTE)
- **계층 데이터**(카테고리 트리, 조직도) 탐색 (Recursive CTE)

> CTE(Common Table Expression)는 `WITH` 절로 정의하는 이름 붙은 임시 결과 집합입니다.
> PG12부터 단일 참조 CTE는 자동으로 인라인되어 서브쿼리처럼 최적화됩니다.
> — [PostgreSQL: WITH Queries](https://www.postgresql.org/docs/17/queries-with.html)

### 다단계 ETL 변환

```sql
-- 상황: 일별 매출 리포트를 원본 주문 데이터에서 단계적으로 집계

WITH daily_orders AS (
    -- 1단계: 정규화 및 필터링
    SELECT
        date_trunc('day', created_at)::date AS order_date,
        user_id,
        total_amount,
        status
    FROM orders
    WHERE created_at >= '2026-02-01'
      AND status IN ('completed', 'refunded')
),
user_totals AS (
    -- 2단계: 사용자별 일별 집계
    SELECT
        order_date,
        user_id,
        SUM(CASE WHEN status = 'completed' THEN total_amount ELSE 0 END) AS revenue,
        SUM(CASE WHEN status = 'refunded' THEN total_amount ELSE 0 END) AS refunds,
        COUNT(*) AS order_count
    FROM daily_orders
    GROUP BY order_date, user_id
),
daily_summary AS (
    -- 3단계: 일별 전체 집계
    SELECT
        order_date,
        SUM(revenue) AS total_revenue,
        SUM(refunds) AS total_refunds,
        SUM(order_count) AS total_orders,
        COUNT(DISTINCT user_id) AS unique_customers
    FROM user_totals
    GROUP BY order_date
)
-- 4단계: 파생 메트릭 계산
SELECT
    order_date,
    total_revenue,
    total_refunds,
    total_revenue - total_refunds AS net_revenue,
    total_orders,
    unique_customers,
    ROUND(total_revenue / NULLIF(unique_customers, 0), 2) AS arpu
FROM daily_summary
ORDER BY order_date;
```

### Data-Modifying CTE — 아카이빙

```sql
-- 상황: 1년 이상 된 주문을 아카이브 테이블로 이동 (원자적 실행)
WITH archived AS (
    DELETE FROM orders
    WHERE created_at < '2025-01-01'
    RETURNING *
)
INSERT INTO orders_archive
SELECT * FROM archived;
-- DELETE와 INSERT가 같은 스냅샷에서 실행되므로 데이터 유실 없음
```

### Data-Modifying CTE — 변경 로그

```sql
-- 상황: 가격 일괄 인상 후 변경 내역을 로그 테이블에 기록
WITH updated AS (
    UPDATE products
    SET price = price * 1.10
    WHERE category_id = 5
    RETURNING id, name, price AS new_price
)
INSERT INTO price_change_log (product_id, product_name, new_price, changed_at)
SELECT id, name, new_price, NOW()
FROM updated;
```

### MATERIALIZED vs NOT MATERIALIZED (PG12+)

```sql
-- 비싼 계산을 여러 번 참조 → MATERIALIZED로 한 번만 실행
WITH expensive_calc AS MATERIALIZED (
    SELECT user_id, compute_risk_score(profile_data) AS score
    FROM users
)
SELECT a.user_id, a.score, b.score
FROM expensive_calc a
JOIN expensive_calc b ON a.score = b.score AND a.user_id <> b.user_id;

-- 큰 테이블인데 WHERE로 크게 줄어드는 경우 → NOT MATERIALIZED로 인라인
WITH all_orders AS NOT MATERIALIZED (
    SELECT * FROM orders  -- 5천만 행
)
SELECT * FROM all_orders WHERE order_id = 12345;
-- NOT MATERIALIZED → WHERE가 orders 테이블 스캔에 직접 push-down되어
-- 인덱스 사용 가능
```

### Recursive CTE — 카테고리 트리

```sql
-- 상황: 이커머스 카테고리 계층 구조에서 breadcrumb(경로) 생성
WITH RECURSIVE category_tree AS (
    -- 기본 케이스: 최상위 카테고리
    SELECT
        id, name, parent_id,
        name::text AS breadcrumb,
        1 AS depth,
        ARRAY[id] AS path
    FROM categories
    WHERE parent_id IS NULL

    UNION ALL

    -- 재귀: 자식 카테고리
    SELECT
        c.id, c.name, c.parent_id,
        ct.breadcrumb || ' > ' || c.name,
        ct.depth + 1,
        ct.path || c.id
    FROM categories c
    JOIN category_tree ct ON c.parent_id = ct.id
)
SELECT id, name, breadcrumb, depth
FROM category_tree
ORDER BY path;

-- 결과 예시:
-- 1 | 전자제품        | 전자제품                          | 1
-- 2 | 컴퓨터          | 전자제품 > 컴퓨터                  | 2
-- 5 | 노트북          | 전자제품 > 컴퓨터 > 노트북          | 3
```

---

## 5. Window Function — 분석 쿼리

### 언제 쓰는가

- **전일 대비, 전월 대비, 전년 대비** 비교 (LAG/LEAD)
- **이동 평균, 누적 합계** 계산 (SUM/AVG OVER)
- **중복 제거** (ROW_NUMBER로 최신 행만 남기기)
- **고객 등급 분류** (NTILE, PERCENT_RANK)
- **카테고리별 Top-N** (RANK, DENSE_RANK)

> Window Function은 GROUP BY와 달리 행을 접지 않고, 각 행에 집계 결과를 붙여줍니다.
> — [PostgreSQL: Window Functions](https://www.postgresql.org/docs/17/functions-window.html)

### 핵심 함수 요약

| 함수 | 설명 | 대표 사용 사례 |
|------|------|--------------|
| `ROW_NUMBER()` | 파티션 내 순번 (1, 2, 3, ...) | 중복 제거, 최신 행 선택 |
| `RANK()` | 동률 시 같은 순위, 다음 순위 건너뜀 (1, 2, 2, 4) | 랭킹 |
| `DENSE_RANK()` | 동률 시 같은 순위, 다음 순위 안 건너뜀 (1, 2, 2, 3) | Top-N |
| `LAG(val, offset)` | 이전 행의 값 | 전일 대비 변화량 |
| `LEAD(val, offset)` | 다음 행의 값 | 다음 기간 예측 비교 |
| `SUM() OVER` | 윈도우 프레임 내 합계 | 누적 합계, 이동 합계 |
| `AVG() OVER` | 윈도우 프레임 내 평균 | 이동 평균 |
| `NTILE(n)` | n개 버킷으로 균등 분할 | 고객 등급 (상위 25%, 50%...) |
| `FIRST_VALUE()` | 프레임의 첫 번째 값 | 기준점 대비 변화 |
| `PERCENT_RANK()` | 상대적 순위 (0~1) | 백분위 |

### 패턴 1: 전일 대비 매출 변화 (LAG)

```sql
-- 상황: 일별 매출 대시보드에 전일 대비 변화량과 변화율 표시
SELECT
    order_date,
    daily_revenue,
    LAG(daily_revenue) OVER (ORDER BY order_date) AS prev_day,
    daily_revenue - LAG(daily_revenue) OVER (ORDER BY order_date) AS change,
    ROUND(
        (daily_revenue - LAG(daily_revenue) OVER (ORDER BY order_date))
        / NULLIF(LAG(daily_revenue) OVER (ORDER BY order_date), 0) * 100, 1
    ) AS change_pct
FROM (
    SELECT
        created_at::date AS order_date,
        SUM(total_amount) AS daily_revenue
    FROM orders
    WHERE status = 'completed'
    GROUP BY 1
) daily
ORDER BY order_date;
```

### 패턴 2: 7일 이동 평균 (Moving Average)

```sql
-- 상황: 일별 변동이 심한 매출 데이터를 부드럽게 시각화
SELECT
    order_date,
    daily_revenue,
    ROUND(AVG(daily_revenue) OVER (
        ORDER BY order_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 2) AS moving_avg_7d,
    SUM(daily_revenue) OVER (
        ORDER BY order_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_revenue
FROM daily_revenue_summary;

-- ROWS BETWEEN 6 PRECEDING AND CURRENT ROW = 현재 행 포함 7개 행
-- ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW = 처음부터 현재까지 누적
```

### 패턴 3: 중복 제거 (ROW_NUMBER)

```sql
-- 상황: 이벤트 스트림에 동일 이벤트가 여러 번 들어옴
-- → user_id + event_type 기준 가장 최근 이벤트만 남기기
WITH deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY user_id, event_type
            ORDER BY created_at DESC
        ) AS rn
    FROM event_logs
)
SELECT * FROM deduplicated WHERE rn = 1;

-- 실제 삭제하려면:
DELETE FROM event_logs
WHERE id IN (
    SELECT id FROM (
        SELECT id,
            ROW_NUMBER() OVER (
                PARTITION BY user_id, event_type
                ORDER BY created_at DESC
            ) AS rn
        FROM event_logs
    ) ranked
    WHERE rn > 1
);
```

### 패턴 4: 고객 등급 분류 (NTILE)

```sql
-- 상황: 고객을 구매 금액 기준으로 4등급(VIP, High, Medium, Low)으로 분류
SELECT
    user_id,
    total_spent,
    NTILE(4) OVER (ORDER BY total_spent DESC) AS quartile,
    CASE NTILE(4) OVER (ORDER BY total_spent DESC)
        WHEN 1 THEN 'VIP'
        WHEN 2 THEN 'High'
        WHEN 3 THEN 'Medium'
        WHEN 4 THEN 'Low'
    END AS tier
FROM (
    SELECT user_id, SUM(total_amount) AS total_spent
    FROM orders WHERE status = 'completed'
    GROUP BY user_id
) user_spending;
```

### 패턴 5: 카테고리별 Top-3 (DENSE_RANK)

```sql
-- 상황: 카테고리별 베스트셀러 상위 3개 추출
SELECT category_id, product_name, total_sold
FROM (
    SELECT
        p.category_id,
        p.name AS product_name,
        SUM(oi.quantity) AS total_sold,
        DENSE_RANK() OVER (
            PARTITION BY p.category_id
            ORDER BY SUM(oi.quantity) DESC
        ) AS rank
    FROM products p
    JOIN order_items oi ON p.id = oi.product_id
    GROUP BY p.category_id, p.name
) ranked
WHERE rank <= 3
ORDER BY category_id, rank;
```

### WINDOW 절로 중복 정의 제거

```sql
-- 같은 윈도우를 여러 함수에서 사용할 때
SELECT
    order_date,
    daily_revenue,
    ROW_NUMBER() OVER w AS day_number,
    SUM(daily_revenue) OVER w AS cumulative,
    AVG(daily_revenue) OVER w AS running_avg,
    LAG(daily_revenue) OVER w AS prev_day
FROM daily_revenue_summary
WINDOW w AS (ORDER BY order_date)
ORDER BY order_date;
```

---

## 6. LATERAL JOIN — 그룹별 Top-N

### 언제 쓰는가

- **"사용자별 최근 주문 3건"** 같은 그룹별 Top-N 쿼리
- **서브쿼리가 외부 테이블의 값을 참조**해야 할 때 (Correlated Subquery의 테이블 버전)
- **JSONB 배열 언네스팅**을 관계형 데이터와 조인할 때

> `LATERAL`은 FROM 절의 서브쿼리가 자신보다 앞에 나오는 테이블의 컬럼을 참조할 수 있게 합니다.
> 각 외부 행에 대해 서브쿼리가 한 번씩 평가됩니다.
> — [PostgreSQL: LATERAL Subqueries](https://www.postgresql.org/docs/17/queries-table-expressions.html#QUERIES-LATERAL)

### 그룹별 Top-N (핵심 패턴)

```sql
-- 상황: 고객별 최근 주문 3건을 조회 (고객 프로필 페이지)
SELECT
    u.user_id,
    u.email,
    recent.*
FROM users u
CROSS JOIN LATERAL (
    SELECT order_id, created_at, total_amount, status
    FROM orders o
    WHERE o.user_id = u.user_id
    ORDER BY o.created_at DESC
    LIMIT 3
) recent
WHERE u.created_at > '2025-01-01';

-- 필수 인덱스:
CREATE INDEX idx_orders_user_date ON orders (user_id, created_at DESC);
```

#### LATERAL vs Window Function 성능 비교

```sql
-- Window Function 방식: 전체 행을 스캔 후 필터링
-- (orders 전체를 읽고 ROW_NUMBER를 매긴 뒤 rn <= 3만 남김)
WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) AS rn
    FROM orders
)
SELECT * FROM ranked WHERE rn <= 3;

-- LATERAL 방식: 인덱스를 사용하여 각 사용자마다 3건만 읽음
-- → 인덱스가 있으면 LATERAL이 압도적으로 빠름 (특히 N이 작을 때)
SELECT u.user_id, r.*
FROM users u
CROSS JOIN LATERAL (
    SELECT order_id, created_at, total_amount
    FROM orders WHERE user_id = u.user_id
    ORDER BY created_at DESC
    LIMIT 3
) r;
```

> **일반적인 규칙**: LIMIT이 작고(1~5), 인덱스가 있으면 LATERAL이 빠릅니다.
> LIMIT이 없거나 크면 Window Function이 더 효율적일 수 있습니다.
> — [Crunchy Data: Iterators with LATERAL Joins](https://www.crunchydata.com/blog/iterators-in-postgresql-with-lateral-joins)

### LEFT JOIN LATERAL — 데이터가 없는 행도 유지

```sql
-- 상황: 모든 사용자의 통계를 조회 (주문이 없는 사용자도 포함)
SELECT u.user_id, u.email, stats.*
FROM users u
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) AS total_orders,
        SUM(total_amount) AS lifetime_value,
        MAX(created_at) AS last_order_date
    FROM orders
    WHERE user_id = u.user_id
) stats ON true;
-- LEFT JOIN LATERAL ... ON true: stats가 NULL이어도 u 행은 유지
```

### LATERAL + generate_series — 시간 버킷 분석

```sql
-- 상황: 상품별 최근 7일 일별 판매량 (0건인 날도 표시)
SELECT
    p.product_id, p.name, d.day,
    COALESCE(sales.qty, 0) AS quantity_sold
FROM products p
CROSS JOIN generate_series(
    CURRENT_DATE - 6, CURRENT_DATE, INTERVAL '1 day'
) AS d(day)
LEFT JOIN LATERAL (
    SELECT SUM(oi.quantity) AS qty
    FROM order_items oi
    JOIN orders o ON o.order_id = oi.order_id
    WHERE oi.product_id = p.product_id
      AND o.created_at::date = d.day
) sales ON true
ORDER BY p.product_id, d.day;
```

---

## 7. JSON/JSONB 처리

### 언제 쓰는가

- **API 응답 로그, 이벤트 페이로드** 같은 반정형(semi-structured) 데이터 저장/조회
- **스키마가 자주 바뀌는 데이터**를 유연하게 처리
- **JSON 문서를 관계형으로 변환**하여 분석 (JSON → 테이블)

### 필수 연산자

```sql
-- 테스트 데이터
CREATE TABLE events (
    id BIGSERIAL PRIMARY KEY,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO events (payload) VALUES ('{
    "event_type": "purchase",
    "user": {"id": 42, "name": "Alice"},
    "items": [
        {"product": "Keyboard", "qty": 1, "price": 79.99},
        {"product": "Mouse", "qty": 2, "price": 29.99}
    ],
    "metadata": {"source": "mobile", "version": "2.1"}
}');

-- 값 추출
SELECT
    payload ->> 'event_type'              AS event_type,    -- TEXT로 추출
    payload -> 'user' ->> 'name'          AS user_name,     -- 중첩 TEXT
    payload #>> '{user,id}'               AS user_id,       -- 깊은 경로 TEXT
    (payload -> 'user' ->> 'id')::INT     AS user_id_int,   -- 타입 캐스팅
    payload['metadata']['source']         AS source          -- PG14+ 첨자 문법
FROM events;
```

### 배열 언네스팅 (jsonb_array_elements)

```sql
-- 상황: 주문 이벤트의 items 배열을 행으로 풀어서 상품별 분석
SELECT
    e.id AS event_id,
    e.payload ->> 'event_type' AS event_type,
    item ->> 'product' AS product,
    (item ->> 'qty')::INT AS quantity,
    (item ->> 'price')::NUMERIC AS price
FROM events e,
     jsonb_array_elements(e.payload -> 'items') AS item
WHERE e.payload ->> 'event_type' = 'purchase';

-- 결과:
-- event_id | event_type | product  | quantity | price
-- ---------+------------+----------+----------+------
--        1 | purchase   | Keyboard |        1 | 79.99
--        1 | purchase   | Mouse    |        2 | 29.99
```

### 🆕 PG17: JSON_TABLE — 관계형 변환의 끝판왕

```sql
-- 상황: JSON 이벤트 로그를 정규 관계형 테이블 형태로 변환
-- 기존에는 jsonb_array_elements + LATERAL JOIN 조합이 필요했지만
-- JSON_TABLE 하나로 해결
SELECT jt.*
FROM events e,
     JSON_TABLE(
         e.payload,
         '$.items[*]'
         COLUMNS (
             row_num   FOR ORDINALITY,
             product   TEXT    PATH '$.product',
             quantity  INT     PATH '$.qty',
             price     NUMERIC PATH '$.price'
         )
     ) AS jt
WHERE e.payload ->> 'event_type' = 'purchase';

-- 중첩 경로 (Nested Path): 주문 → 항목 → 옵션까지 한 번에
SELECT jt.*
FROM orders_json o,
     JSON_TABLE(
         o.data,
         '$.orders[*]'
         COLUMNS (
             order_id   INT  PATH '$.order_id',
             customer   TEXT PATH '$.customer_name',
             NESTED PATH '$.items[*]' COLUMNS (
                 product    TEXT PATH '$.product',
                 quantity   INT  PATH '$.quantity'
             )
         )
     ) AS jt;

-- EXISTS PATH: 키 존재 여부 체크
SELECT jt.*
FROM events e,
     JSON_TABLE(
         e.payload, '$'
         COLUMNS (
             event_type  TEXT    PATH '$.event_type',
             has_items   BOOLEAN EXISTS PATH '$.items',
             has_meta    BOOLEAN EXISTS PATH '$.metadata'
         )
     ) AS jt;
```

> JSON_TABLE은 SQL/JSON 표준(SQL:2016)을 구현한 것으로,
> 복잡한 `jsonb_array_elements` + `LATERAL JOIN` 체인을 하나의 선언적 구문으로 대체합니다.
> — [PostgreSQL 17: JSON_TABLE](https://www.postgresql.org/docs/17/functions-json.html#FUNCTIONS-SQLJSON-TABLE)

### 관계형 → JSON 빌드

```sql
-- 상황: REST API 응답을 DB에서 직접 JSON으로 구성
SELECT jsonb_build_object(
    'user_id', u.id,
    'email', u.email,
    'orders', (
        SELECT jsonb_agg(
            jsonb_build_object(
                'order_id', o.order_id,
                'total', o.total_amount,
                'items', (
                    SELECT jsonb_agg(
                        jsonb_build_object('product', p.name, 'qty', oi.quantity)
                    )
                    FROM order_items oi
                    JOIN products p ON p.id = oi.product_id
                    WHERE oi.order_id = o.order_id
                )
            )
        )
        FROM orders o WHERE o.user_id = u.id
    )
) AS user_document
FROM users u WHERE u.id = 42;
```

### JSONB 인덱싱

```sql
-- GIN 인덱스: @> (containment) 쿼리에 최적
CREATE INDEX idx_events_payload ON events USING GIN (payload);
SELECT * FROM events WHERE payload @> '{"event_type": "purchase"}';

-- jsonb_path_ops: @> 전용이지만 50~80% 더 작음
CREATE INDEX idx_events_pathops ON events USING GIN (payload jsonb_path_ops);

-- 특정 키에 대한 B-tree 인덱스 (등호/범위 검색)
CREATE INDEX idx_events_user_id ON events ((payload ->> 'user_id'));
SELECT * FROM events WHERE payload ->> 'user_id' = '42';
```

---

## 8. 파티셔닝 — 대규모 테이블 관리

### 언제 쓰는가

- **수억 행의 시계열 데이터** (이벤트 로그, 센서 데이터, 주문) 관리
- **오래된 데이터 삭제**를 DELETE 대신 **파티션 DROP**으로 즉시 처리
- **데이터 적재 시 기존 파티션에 락 없이** 새 파티션을 추가

> 파티셔닝은 논리적으로 하나의 테이블을 물리적으로 여러 조각으로 나눕니다.
> 쿼리 시 WHERE 조건에 맞는 파티션만 스캔합니다 (파티션 프루닝).
> — [PostgreSQL: Table Partitioning](https://www.postgresql.org/docs/17/ddl-partitioning.html)

### Range 파티셔닝 (날짜 기반 — 가장 흔한 패턴)

```sql
-- 이벤트 로그 테이블 (월별 파티셔닝)
CREATE TABLE event_logs (
    event_id    BIGSERIAL,
    event_type  TEXT NOT NULL,
    user_id     BIGINT,
    payload     JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (event_id, created_at)  -- 파티션 키는 PK에 포함되어야 함
) PARTITION BY RANGE (created_at);

-- 월별 파티션 생성
CREATE TABLE event_logs_2026_01 PARTITION OF event_logs
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE event_logs_2026_02 PARTITION OF event_logs
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');

-- 기본 파티션 (매칭되지 않는 데이터 수집)
CREATE TABLE event_logs_default PARTITION OF event_logs DEFAULT;

-- 인덱스는 부모 테이블에 만들면 자동으로 각 파티션에 생성됨
CREATE INDEX idx_event_logs_user ON event_logs (user_id, created_at);
```

### 무중단 데이터 적재 (ATTACH PARTITION)

```sql
-- 상황: 새로운 월의 데이터를 무중단으로 적재

-- 1단계: 독립 테이블로 생성 (부모 테이블에 락 없음)
CREATE TABLE event_logs_2026_03 (
    LIKE event_logs INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES
);

-- 2단계: 대량 적재 (부모 테이블과 무관하게 진행)
COPY event_logs_2026_03 FROM '/data/events_march.csv' WITH (FORMAT csv, HEADER);

-- 3단계: CHECK 제약 추가 (ATTACH 시 검증 스캔 생략)
ALTER TABLE event_logs_2026_03
    ADD CONSTRAINT chk_2026_03
    CHECK (created_at >= '2026-03-01' AND created_at < '2026-04-01');

-- 4단계: 파티션으로 붙이기 (CHECK 덕분에 즉시 완료)
ALTER TABLE event_logs ATTACH PARTITION event_logs_2026_03
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
```

### 오래된 데이터 삭제 (DROP/DETACH)

```sql
-- DELETE FROM으로 수억 행을 지우면: 수십 분 + dead tuple + VACUUM 필요
-- 파티션 DROP은: 즉시 완료 (밀리초 단위)

-- PG14+: CONCURRENTLY로 읽기 차단 없이 분리
ALTER TABLE event_logs DETACH PARTITION event_logs_2024_01 CONCURRENTLY;

-- 분리된 테이블은 독립적으로 백업/삭제 가능
-- pg_dump -t event_logs_2024_01 dbname > archive.sql
DROP TABLE event_logs_2024_01;
```

### 파티션 프루닝 확인

```sql
EXPLAIN (ANALYZE)
SELECT * FROM event_logs
WHERE created_at >= '2026-02-01' AND created_at < '2026-03-01';
-- 출력에서 확인: "Partitions selected: 1 (out of 15)"
```

---

## 9. Materialized View — 사전 집계

### 언제 쓰는가

- **대시보드 쿼리가 매번 수초~수분** 걸릴 때 (사전 집계로 밀리초 응답)
- **BI 도구(Metabase, Grafana, Tableau)용 비정규화 테이블** 생성
- **복잡한 JOIN의 결과를 캐싱**하여 반복 조회 시 성능 향상

> Materialized View는 쿼리 결과를 물리적으로 저장하는 테이블입니다.
> 일반 뷰와 달리 데이터를 디스크에 저장하며, 수동으로 `REFRESH`해야 최신화됩니다.
> — [PostgreSQL: CREATE MATERIALIZED VIEW](https://www.postgresql.org/docs/17/sql-creatematerializedview.html)

### 일별 매출 대시보드

```sql
-- 복잡한 JOIN + 집계를 Materialized View로 캐싱
CREATE MATERIALIZED VIEW mv_daily_sales AS
SELECT
    o.created_at::date AS sale_date,
    p.category_id,
    COUNT(*) AS order_count,
    SUM(oi.quantity) AS units_sold,
    SUM(oi.quantity * oi.unit_price) AS revenue,
    AVG(oi.unit_price) AS avg_price
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
JOIN products p ON p.id = oi.product_id
WHERE o.status = 'completed'
GROUP BY 1, 2
WITH DATA;  -- 즉시 데이터 채우기 (WITH NO DATA는 나중에 채우기)

-- CONCURRENTLY 갱신을 위해 UNIQUE 인덱스 필수
CREATE UNIQUE INDEX idx_mv_daily_sales ON mv_daily_sales (sale_date, category_id);

-- 조회용 인덱스
CREATE INDEX idx_mv_daily_sales_date ON mv_daily_sales (sale_date);
```

### REFRESH 패턴

```sql
-- 일반 갱신: ACCESS EXCLUSIVE 락 (조회 차단됨)
REFRESH MATERIALIZED VIEW mv_daily_sales;

-- CONCURRENTLY 갱신: 조회 차단 없음 (UNIQUE 인덱스 필요)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_sales;
-- 내부적으로: 새 결과 생성 → 기존 데이터와 diff → INSERT/UPDATE/DELETE 적용
-- 일반 갱신보다 느리지만 프로덕션에서는 필수
```

### 자동 갱신 설정 (pg_cron 사용)

```sql
-- pg_cron으로 매일 새벽 2시 갱신
SELECT cron.schedule('refresh_daily_sales', '0 2 * * *',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_sales');
```

---

## 10. Temp / Unlogged 테이블 — 스테이징

### 언제 쓰는가

- **ETL 중간 결과**를 임시 저장 (CTE로는 인덱스를 못 달 때)
- **대량 데이터 적재 시 스테이징 영역** (WAL 오버헤드 제거)
- **복잡한 쿼리의 중간 단계**에서 인덱스 + ANALYZE가 필요할 때

### 성능 비교

| 특성 | Regular Table | Unlogged Table | Temp Table |
|------|-------------|----------------|------------|
| 쓰기 속도 | 기준 | **2~3배 빠름** | **2~3배 빠름** |
| WAL 생성 | ✅ | ❌ | ❌ |
| 크래시 복구 | ✅ | ❌ (TRUNCATE됨) | ❌ (DROP됨) |
| 레플리카 전파 | ✅ | ❌ | ❌ |
| 다른 세션에서 보임 | ✅ | ✅ | ❌ |
| Autovacuum | ✅ | ✅ | ❌ (수동 필요) |

### Unlogged 테이블로 스테이징

```sql
-- 상황: 대량 이벤트 데이터를 검증 후 프로덕션 테이블에 적재
BEGIN;

CREATE UNLOGGED TABLE stg_events (
    event_id    TEXT,
    user_id     INTEGER,
    event_type  TEXT,
    payload     JSONB,
    event_time  TIMESTAMPTZ
);

-- WAL 없이 빠르게 적재
COPY stg_events FROM PROGRAM 'zcat /data/events.csv.gz'
    WITH (FORMAT csv, HEADER true, ON_ERROR ignore);

-- 중복 제거
DELETE FROM stg_events WHERE event_id IN (
    SELECT event_id FROM (
        SELECT event_id,
            ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY event_time DESC) AS rn
        FROM stg_events
    ) t WHERE rn > 1
);

-- 프로덕션 적재
INSERT INTO event_logs (event_id, user_id, event_type, payload, created_at)
SELECT event_id, user_id, event_type, payload, event_time
FROM stg_events
ON CONFLICT (event_id) DO NOTHING;

DROP TABLE stg_events;
COMMIT;
```

### Temp 테이블로 복잡한 분석 가속

```sql
-- 상황: CTE로는 인덱스를 못 다는 복잡한 중간 결과가 필요할 때
CREATE TEMP TABLE tmp_user_metrics AS
SELECT
    user_id,
    COUNT(*) AS total_orders,
    SUM(total_amount) AS lifetime_value,
    MAX(created_at) AS last_order_date
FROM orders WHERE status = 'completed'
GROUP BY user_id;

-- 인덱스 추가 + 통계 갱신 (CTE에서는 불가능한 것들)
CREATE INDEX ON tmp_user_metrics (user_id);
ANALYZE tmp_user_metrics;

-- 이제 다른 테이블과 효율적으로 JOIN 가능
SELECT u.email, m.total_orders, m.lifetime_value,
    NTILE(5) OVER (ORDER BY m.lifetime_value DESC) AS value_quintile
FROM users u
JOIN tmp_user_metrics m ON u.id = m.user_id
WHERE m.total_orders >= 5;
```

---

## 11. generate_series — 시계열 생성과 갭 채우기

### 언제 쓰는가

- **대시보드에서 데이터가 없는 날짜/시간을 0으로 표시**해야 할 때
- **시계열 분석을 위한 연속적인 시간 축** 생성
- **테스트 데이터 대량 생성**

> `generate_series()`는 지정된 범위와 간격으로 행을 생성하는 SRF(Set-Returning Function)입니다.
> — [PostgreSQL: Set Returning Functions](https://www.postgresql.org/docs/17/functions-srf.html)

### 갭 채우기 (핵심 패턴)

```sql
-- 상황: 일별 매출 차트에서 주문이 0건인 날도 표시해야 함
SELECT
    d.day,
    COALESCE(SUM(o.total_amount), 0) AS revenue,
    COALESCE(COUNT(o.order_id), 0) AS order_count
FROM generate_series(
    '2026-01-01'::date,
    '2026-01-31'::date,
    INTERVAL '1 day'
) AS d(day)
LEFT JOIN orders o ON o.created_at::date = d.day AND o.status = 'completed'
GROUP BY d.day
ORDER BY d.day;

-- 결과: 1월 1일~31일까지 빠짐없이 표시, 주문 없는 날은 0
```

### 시간대별 이벤트 카운트

```sql
-- 상황: 시간대별 트래픽 히트맵 (24시간 × 0 채우기)
WITH hours AS (
    SELECT ts FROM generate_series(
        date_trunc('day', NOW()),
        date_trunc('day', NOW()) + INTERVAL '23 hours',
        INTERVAL '1 hour'
    ) AS ts
)
SELECT
    h.ts AS hour,
    COALESCE(COUNT(e.id), 0) AS event_count
FROM hours h
LEFT JOIN event_logs e
    ON e.created_at >= h.ts AND e.created_at < h.ts + INTERVAL '1 hour'
GROUP BY h.ts
ORDER BY h.ts;
```

### 테스트 데이터 생성

```sql
-- 10만 명의 테스트 사용자
INSERT INTO users (email, username, created_at)
SELECT
    'user' || n || '@test.com',
    'user_' || n,
    NOW() - (random() * INTERVAL '365 days')
FROM generate_series(1, 100000) AS n;

-- 50만 건의 랜덤 주문
INSERT INTO orders (user_id, created_at, total_amount, status)
SELECT
    (random() * 99999 + 1)::INT,
    NOW() - (random() * INTERVAL '730 days'),
    ROUND((random() * 500 + 10)::NUMERIC, 2),
    (ARRAY['pending','completed','shipped','cancelled'])[floor(random()*4+1)::int]
FROM generate_series(1, 500000);

-- IoT 센서 데이터 (10개 센서, 5분 간격, 30일)
INSERT INTO sensor_readings (sensor_id, reading_time, temperature, humidity)
SELECT
    (n % 10) + 1,
    ts,
    ROUND((20 + random() * 15)::NUMERIC, 1),
    ROUND((40 + random() * 40)::NUMERIC, 1)
FROM generate_series(
    NOW() - INTERVAL '30 days', NOW(), INTERVAL '5 minutes'
) AS ts
CROSS JOIN generate_series(1, 10) AS n;
```

---

## 12. 배치 처리 패턴

### 언제 쓰는가

- **수백만 행을 UPDATE/DELETE**할 때 (한 번에 하면 락 + WAL 폭발)
- **ETL 작업을 여러 워커가 동시에 처리**할 때 (Advisory Lock)
- **페이지네이션으로 대량 데이터를 순차 처리**할 때

### 청크 단위 DELETE

```sql
-- 상황: 1년 이상 된 이벤트 로그 1억 건 삭제
-- ❌ 나쁜 예: 한 번에 삭제 (트랜잭션 너무 길어짐, WAL 폭발, 테이블 락)
DELETE FROM event_logs WHERE created_at < NOW() - INTERVAL '1 year';

-- ✅ 좋은 예: 1만 건씩 청크 삭제
-- 반복 실행 (영향받는 행이 0이 될 때까지)
WITH batch AS (
    SELECT event_id
    FROM event_logs
    WHERE created_at < NOW() - INTERVAL '1 year'
    ORDER BY event_id
    LIMIT 10000
    FOR UPDATE SKIP LOCKED  -- 다른 워커가 처리 중인 행은 건너뜀
)
DELETE FROM event_logs
WHERE event_id IN (SELECT event_id FROM batch);

-- 쉘 스크립트로 반복:
-- while [ $(psql -tAc "WITH batch AS (...) DELETE ... RETURNING 1" | wc -l) -gt 0 ]; do sleep 0.1; done
```

### Keyset 페이지네이션 (OFFSET 대체)

```sql
-- ❌ OFFSET: 깊은 페이지일수록 느려짐 (건너뛸 행을 모두 읽어야 함)
SELECT * FROM event_logs ORDER BY created_at, event_id LIMIT 100 OFFSET 1000000;

-- ✅ Keyset: 항상 일정한 속도 (인덱스로 바로 점프)
-- 첫 페이지:
SELECT * FROM event_logs
ORDER BY created_at, event_id
LIMIT 100;

-- 다음 페이지 (이전 페이지의 마지막 행 기준):
SELECT * FROM event_logs
WHERE (created_at, event_id) > ('2025-03-15 14:22:00+00', 9999875)
ORDER BY created_at, event_id
LIMIT 100;

-- 필수 인덱스:
CREATE INDEX idx_event_logs_cursor ON event_logs (created_at, event_id);
```

> Keyset 페이지네이션은 100만 번째 페이지도 첫 페이지와 동일한 속도입니다.
> OFFSET은 데이터가 많아질수록 선형적으로 느려집니다.
> — [Citus Data: Five Ways to Paginate](https://www.citusdata.com/blog/2016/03/30/five-ways-to-paginate/)

### Advisory Lock — 동시 작업 조율

```sql
-- 상황: 같은 ETL 작업이 동시에 실행되지 않도록 보장
DO $$
BEGIN
    -- 논블로킹으로 락 시도
    IF NOT pg_try_advisory_lock(hashtext('daily_sales_etl')) THEN
        RAISE NOTICE 'ETL 작업이 이미 실행 중입니다. 건너뜁니다.';
        RETURN;
    END IF;

    -- ETL 작업 실행
    PERFORM refresh_daily_sales();

    -- 락 해제
    PERFORM pg_advisory_unlock(hashtext('daily_sales_etl'));
END $$;

-- 워커 큐 패턴: 여러 워커가 작업을 나눠서 처리
WITH next_job AS (
    SELECT job_id
    FROM job_queue
    WHERE status = 'pending'
      AND pg_try_advisory_xact_lock(job_id)  -- 원자적으로 작업 선점
    ORDER BY priority, created_at
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
UPDATE job_queue
SET status = 'processing', worker_id = pg_backend_pid(), started_at = NOW()
WHERE job_id = (SELECT job_id FROM next_job)
RETURNING *;
```

---

## 13. EXPLAIN ANALYZE — 쿼리 최적화

### 언제 쓰는가

- **"이 쿼리가 왜 느린지"** 원인을 파악할 때
- **인덱스가 제대로 사용되는지** 확인할 때
- **쿼리 최적화 전후 성능 비교**

### 기본 사용법

```sql
-- 실행 계획 + 실제 실행 통계 + I/O 통계
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.*, u.email
FROM orders o
JOIN users u ON u.id = o.user_id
WHERE o.created_at > '2026-01-01'
  AND o.status = 'completed';

-- JSON 포맷 (explain.dalibo.com에 붙여넣기용)
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT ...;
```

### 실행 계획 읽는 법 — 핵심 노드

| 노드 | 의미 | 좋음/나쁨 |
|------|------|----------|
| **Seq Scan** | 테이블 전체를 순차 스캔 | ⚠️ 큰 테이블에서는 인덱스 필요 |
| **Index Scan** | 인덱스로 행을 직접 찾음 | ✅ 이상적 |
| **Bitmap Heap Scan** | 인덱스로 위치를 모은 후 한꺼번에 읽음 | ✅ 중간 선택도에 적합 |
| **Nested Loop** | 외부 행마다 내부를 반복 스캔 | ✅ 외부가 작을 때 (⚠️ 클 때 느림) |
| **Hash Join** | 한쪽을 해시 테이블로 만들어 조인 | ✅ 대량 조인에 효율적 |
| **Merge Join** | 양쪽이 정렬되어 있을 때 병합 | ✅ 사전 정렬된 데이터에 최적 |
| **Sort** | 정렬 (메모리 또는 디스크) | ⚠️ 디스크 Sort는 work_mem 증가 필요 |

### BUFFERS 해석

```
Buffers: shared hit=1234 read=567
```
- `hit`: 이미 메모리(shared_buffers)에 있던 페이지 수 → 빠름
- `read`: 디스크에서 읽어야 했던 페이지 수 → 느림
- `temp read/written`: 디스크에 쓰인 임시 데이터 → `work_mem` 부족

### 자주 마주치는 문제와 해결

```sql
-- 1. 큰 테이블에서 Seq Scan → 인덱스 추가
-- 문제: Seq Scan on event_logs (actual time=0.01..450.00 rows=50)
CREATE INDEX idx_event_logs_user ON event_logs (user_id);

-- 2. Sort Method: external merge Disk → work_mem 증가
SET work_mem = '256MB';  -- 세션 단위

-- 3. 추정 행 수와 실제 행 수 차이 → 통계 갱신
-- (estimated rows=1) vs (actual rows=50000)
ANALYZE orders;

-- 4. 특정 컬럼의 통계 세분화 (ndistinct가 너무 낮게 추정될 때)
ALTER TABLE orders ALTER COLUMN status SET STATISTICS 1000;
ANALYZE orders;
```

---

## 14. 카탈로그 & 통계 쿼리

### 언제 쓰는가

- **테이블/인덱스 크기 파악** (디스크 용량 관리)
- **미사용 인덱스 찾기** (불필요한 쓰기 오버헤드 제거)
- **Dead tuple 모니터링** (VACUUM 필요성 판단)
- **느린 쿼리 추적** (pg_stat_statements)

### 테이블/인덱스 크기

```sql
SELECT
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total,
    pg_size_pretty(pg_relation_size(relid)) AS table_only,
    pg_size_pretty(pg_indexes_size(relid)) AS indexes
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 20;
```

### 미사용 인덱스 찾기

```sql
-- idx_scan = 0 이면 한 번도 사용 안 된 인덱스 → 삭제 후보
SELECT
    schemaname || '.' || indexrelname AS index_name,
    relname AS table_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size,
    idx_scan AS times_used
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND indexrelname NOT LIKE '%pkey%'  -- PK는 제외
ORDER BY pg_relation_size(indexrelid) DESC;
```

### Dead Tuple & VACUUM 상태

```sql
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
    last_autovacuum,
    last_autoanalyze,
    CASE WHEN n_dead_tup > (50 + 0.2 * n_live_tup)
         THEN 'VACUUM 필요'
         ELSE 'OK'
    END AS status
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC;
```

### pg_stat_statements — 느린 쿼리 Top 20

```sql
-- 확장 설치 (한 번만)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 총 실행 시간 기준 상위 20
SELECT
    calls,
    ROUND(total_exec_time::numeric, 1) AS total_ms,
    ROUND(mean_exec_time::numeric, 1) AS avg_ms,
    ROUND(
        (shared_blks_hit * 100.0 / NULLIF(shared_blks_hit + shared_blks_read, 0))::numeric, 1
    ) AS cache_hit_pct,
    LEFT(query, 100) AS query_preview
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;

-- 캐시 적중률이 낮은 쿼리 (I/O 병목 후보)
SELECT
    LEFT(query, 100) AS query,
    calls,
    shared_blks_hit, shared_blks_read,
    ROUND(shared_blks_hit * 100.0 / NULLIF(shared_blks_hit + shared_blks_read, 0), 1) AS hit_pct
FROM pg_stat_statements
WHERE calls > 100
ORDER BY hit_pct ASC
LIMIT 20;
```

---

## 15. Foreign Data Wrapper — 외부 데이터 연결

### 언제 쓰는가

- **다른 PostgreSQL 인스턴스의 테이블을 직접 조회** (Cross-DB JOIN)
- **CSV 파일을 테이블처럼 SELECT** (일회성 데이터 검증)
- **마이그레이션 중 구/신 시스템 데이터 비교**

### postgres_fdw — 원격 PostgreSQL 조회

```sql
-- 상황: 분석 DB의 세그먼트 데이터를 운영 DB에서 직접 JOIN

-- 1. 확장 설치
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- 2. 원격 서버 정의
CREATE SERVER analytics_db
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'analytics.internal', port '5432', dbname 'analytics');

-- 3. 사용자 매핑
CREATE USER MAPPING FOR labuser
    SERVER analytics_db
    OPTIONS (user 'reader', password 'readonly_pass');

-- 4. 원격 테이블 가져오기
IMPORT FOREIGN SCHEMA public
    LIMIT TO (user_segments, daily_metrics)
    FROM SERVER analytics_db INTO public;

-- 5. 로컬 테이블처럼 조회
SELECT u.email, s.segment, s.score
FROM users u
JOIN user_segments s ON s.user_id = u.id
WHERE s.segment = 'high_value';

-- 성능 튜닝: fetch_size 증가 (기본 100 → 10000)
ALTER SERVER analytics_db OPTIONS (ADD fetch_size '10000');
```

### file_fdw — CSV를 테이블로

```sql
-- 상황: 외부 시스템에서 받은 CSV를 빠르게 검증하고 싶을 때
CREATE EXTENSION IF NOT EXISTS file_fdw;
CREATE SERVER csv_files FOREIGN DATA WRAPPER file_fdw;

CREATE FOREIGN TABLE staging_products (
    sku       TEXT,
    name      TEXT,
    category  TEXT,
    price     NUMERIC(10,2),
    stock     INT
) SERVER csv_files
  OPTIONS (filename '/data/imports/products.csv', format 'csv', header 'true');

-- COPY 없이 즉시 조회
SELECT * FROM staging_products WHERE category = 'Electronics';

-- 검증 후 프로덕션 테이블에 적재
INSERT INTO products (sku, name, category, price, stock)
SELECT sku, name, category, price, stock
FROM staging_products
ON CONFLICT (sku) DO UPDATE SET price = EXCLUDED.price, stock = EXCLUDED.stock;
```

> **성능 참고**: 대량 데이터 적재에는 `COPY`가 `file_fdw`보다 빠릅니다.
> `file_fdw`는 일회성 검증이나 소량 데이터 접근에 적합합니다.
> — [PostgreSQL: file_fdw](https://www.postgresql.org/docs/17/file-fdw.html)

---

## 16. 데이터 품질 보장

### 언제 쓰는가

- **잘못된 데이터가 DB에 들어오는 것을 원천 차단**할 때
- **비즈니스 규칙을 DB 레벨에서 강제**할 때 (애플리케이션 버그와 무관하게)
- **스케줄링/예약 시스템에서 시간 겹침 방지**

### CHECK 제약조건

```sql
CREATE TABLE orders (
    order_id    BIGSERIAL PRIMARY KEY,
    quantity    INT NOT NULL CHECK (quantity > 0),           -- 수량은 양수
    unit_price  NUMERIC(12,2) CHECK (unit_price >= 0),      -- 가격은 0 이상
    discount    NUMERIC(3,2) CHECK (discount BETWEEN 0 AND 1), -- 할인율 0~100%
    status      TEXT CHECK (status IN ('pending','paid','shipped','cancelled'))
);

-- 테이블 레벨 CHECK (여러 컬럼 참조)
CREATE TABLE promotions (
    id          SERIAL PRIMARY KEY,
    start_date  DATE NOT NULL,
    end_date    DATE NOT NULL,
    CHECK (end_date > start_date)  -- 종료일은 시작일 이후
);
```

### EXCLUDE 제약조건 — 시간 겹침 방지

```sql
-- 상황: 회의실 예약 시스템에서 같은 방의 시간이 겹치지 않도록 보장
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE room_bookings (
    id          SERIAL PRIMARY KEY,
    room_id     INT NOT NULL,
    booked_from TIMESTAMPTZ NOT NULL,
    booked_to   TIMESTAMPTZ NOT NULL,
    CHECK (booked_to > booked_from),
    EXCLUDE USING GIST (
        room_id WITH =,
        tstzrange(booked_from, booked_to) WITH &&  -- 시간 범위 겹침 방지
    )
);

-- 성공:
INSERT INTO room_bookings (room_id, booked_from, booked_to)
VALUES (1, '2026-06-01 09:00', '2026-06-01 12:00');

-- 실패 (겹침):
INSERT INTO room_bookings (room_id, booked_from, booked_to)
VALUES (1, '2026-06-01 11:00', '2026-06-01 14:00');
-- ERROR: conflicting key value violates exclusion constraint
```

> EXCLUDE 제약조건은 GiST 인덱스 연산자를 사용하여 "겹침" 같은 복잡한 조건을 DB 레벨에서 강제합니다.
> — [PostgreSQL: Exclusion Constraints](https://www.postgresql.org/docs/17/ddl-constraints.html#DDL-CONSTRAINTS-EXCLUSION)

### Domain 타입 — 재사용 가능한 검증 규칙

```sql
-- 여러 테이블에서 반복되는 검증을 한 번만 정의
CREATE DOMAIN email_address AS TEXT
    NOT NULL
    CHECK (VALUE ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');

CREATE DOMAIN positive_int AS INTEGER
    CHECK (VALUE > 0);

CREATE DOMAIN phone_number AS TEXT
    CHECK (VALUE ~ '^\+?\d{10,15}$');

-- 사용
CREATE TABLE customers (
    id     SERIAL PRIMARY KEY,
    email  email_address,       -- 자동으로 NOT NULL + 이메일 형식 검증
    phone  phone_number,
    age    positive_int
);

CREATE TABLE suppliers (
    id     SERIAL PRIMARY KEY,
    email  email_address,       -- 같은 검증 규칙 재사용
    phone  phone_number
);
```

---

## 실습: ecommerce 데이터로 직접 해보기

> 이 실습은 `docker/init.sql`로 생성된 실제 데이터를 사용합니다.
>
> | 테이블 | 행 수 | 주요 컬럼 |
> |--------|-------|----------|
> | `users` | 10만 | user_id, email, username, is_active, created_at |
> | `products` | 5천 | product_id, category_id, base_price, metadata(JSONB) |
> | `product_variants` | ~1만 | variant_id, product_id, sku, price, attributes(JSONB) |
> | `orders` | 50만 | order_id, user_id, status, total_amount, address_snapshot(JSONB), created_at |
> | `order_items` | ~15만 | order_item_id, order_id, variant_id, quantity, unit_price, subtotal |
> | `payments` | ~20만 | payment_id, order_id, method, amount, status, paid_at |
> | `event_logs` | 100만 | event_id, user_id, event_type, payload(JSONB), created_at — **파티션 테이블** |
> | `categories` | 18 | category_id, parent_id, name, slug, depth — **3단계 계층** |
> | `reviews` | ~수천 | review_id, product_id, user_id, rating, metadata(JSONB) |

```bash
# 실습 시작
docker exec -it pg17-lab psql -U labuser -d ecommerce

# 데이터 건수 확인
SELECT
    'users' AS tbl, count(*) FROM users
UNION ALL SELECT 'products', count(*) FROM products
UNION ALL SELECT 'product_variants', count(*) FROM product_variants
UNION ALL SELECT 'orders', count(*) FROM orders
UNION ALL SELECT 'order_items', count(*) FROM order_items
UNION ALL SELECT 'payments', count(*) FROM payments
UNION ALL SELECT 'event_logs', count(*) FROM event_logs
UNION ALL SELECT 'reviews', count(*) FROM reviews
UNION ALL SELECT 'categories', count(*) FROM categories;
```

---

### 실습 1: COPY — 주문 데이터 CSV 추출 후 재적재

```sql
-- ========================================
-- 1-1. CSV로 추출 (서버 파일시스템)
-- ========================================

-- 2024년 4월 완료 주문만 추출
COPY (
    SELECT order_id, user_id, status, total_amount, created_at
    FROM orders
    WHERE status = 'delivered'
      AND created_at >= '2024-04-01'
      AND created_at < '2024-05-01'
)
TO '/tmp/delivered_orders_2024_04.csv'
WITH (FORMAT csv, HEADER true);

-- 행 수 확인 (쉘에서)
-- docker exec pg17-lab wc -l /tmp/delivered_orders_2024_04.csv

-- ========================================
-- 1-2. 스테이징 테이블에 재적재
-- ========================================
CREATE UNLOGGED TABLE stg_delivered_orders (
    order_id      BIGINT,
    user_id       BIGINT,
    status        VARCHAR(20),
    total_amount  NUMERIC(12,2),
    created_at    TIMESTAMPTZ
);

COPY stg_delivered_orders
FROM '/tmp/delivered_orders_2024_04.csv'
WITH (FORMAT csv, HEADER true);

-- 건수 비교
SELECT
    (SELECT count(*) FROM stg_delivered_orders) AS staged,
    (SELECT count(*) FROM orders
     WHERE status = 'delivered'
       AND created_at >= '2024-04-01'
       AND created_at < '2024-05-01') AS original;

-- ========================================
-- 1-3. 정리
-- ========================================
DROP TABLE stg_delivered_orders;
```

✅ **확인 포인트**: staged와 original 건수가 동일한지 확인하세요.

---

### 실습 2: Upsert — 상품 가격 일괄 갱신

```sql
-- ========================================
-- 2-1. 외부 공급사 가격 피드를 시뮬레이션하는 스테이징 테이블 생성
-- ========================================
CREATE TEMP TABLE supplier_price_feed AS
SELECT
    sku,
    name,
    -- 기존 가격에서 ±10% 변동
    ROUND(price * (0.9 + random() * 0.2), 2) AS new_price
FROM product_variants
WHERE variant_id <= 1000;  -- 첫 1000개 변형만

-- 새 상품 2건 추가 (기존에 없는 SKU)
INSERT INTO supplier_price_feed VALUES
    ('SKU-NEW-001', '신규 상품 A', 29900.00),
    ('SKU-NEW-002', '신규 상품 B', 59900.00);

SELECT count(*) AS feed_count FROM supplier_price_feed;

-- ========================================
-- 2-2. Upsert 실행 (있으면 가격 갱신, 없으면 삽입)
-- ========================================
INSERT INTO product_variants (product_id, sku, name, price)
SELECT
    1 AS product_id,  -- 신규 상품은 임의의 product_id
    f.sku,
    f.name,
    f.new_price
FROM supplier_price_feed f
ON CONFLICT (sku) DO UPDATE SET
    price = EXCLUDED.price,
    -- 이전보다 새 데이터가 실제로 다를 때만 갱신 (불필요한 UPDATE 방지)
    name = CASE
        WHEN product_variants.price <> EXCLUDED.price THEN EXCLUDED.name
        ELSE product_variants.name
    END
RETURNING
    sku,
    (xmax = 0) AS was_inserted,
    price;

-- ========================================
-- 2-3. 결과 확인
-- ========================================
-- 신규 삽입된 상품 확인
SELECT sku, name, price
FROM product_variants
WHERE sku IN ('SKU-NEW-001', 'SKU-NEW-002');

-- 정리 (신규 삽입한 테스트 데이터 제거)
DELETE FROM product_variants WHERE sku IN ('SKU-NEW-001', 'SKU-NEW-002');
```

✅ **확인 포인트**: RETURNING에서 `was_inserted = true`인 행이 2건(신규 SKU)인지 확인하세요.

---

### 실습 3: MERGE — 재고 동기화

```sql
-- ========================================
-- 3-1. 외부 창고 시스템의 재고 피드를 시뮬레이션
-- ========================================
CREATE TEMP TABLE warehouse_stock AS
SELECT
    variant_id,
    -- 일부는 재고 변경, 일부는 동일
    CASE WHEN random() < 0.7
        THEN floor(random() * 300 + 1)::INT
        ELSE quantity  -- 30%는 변경 없음
    END AS new_quantity,
    0 AS new_reserved
FROM inventory
WHERE variant_id <= 500;

-- 존재하지 않는 variant_id 추가 (새 입고)
-- (실제로는 product_variants FK 때문에 inventory에 직접 넣을 수 없으므로
--  기존 variant 중 inventory에 없는 것을 찾아서 추가)
INSERT INTO warehouse_stock
SELECT pv.variant_id, 100, 0
FROM product_variants pv
LEFT JOIN inventory i ON i.variant_id = pv.variant_id
WHERE i.variant_id IS NULL
LIMIT 5;

-- ========================================
-- 3-2. MERGE로 재고 동기화
-- ========================================
MERGE INTO inventory inv
USING warehouse_stock ws ON inv.variant_id = ws.variant_id

-- 기존 재고 + 변경 있음 → 갱신
WHEN MATCHED AND inv.quantity <> ws.new_quantity THEN
    UPDATE SET
        quantity = ws.new_quantity,
        reserved = ws.new_reserved,
        updated_at = NOW()

-- 기존 재고 + 변경 없음 → 아무것도 안 함 (MATCHED이지만 조건 불일치로 스킵)

-- 신규 입고 (inventory에 없는 variant) → 삽입
WHEN NOT MATCHED BY TARGET THEN
    INSERT (variant_id, quantity, reserved, updated_at)
    VALUES (ws.variant_id, ws.new_quantity, ws.new_reserved, NOW())

RETURNING merge_action(), inv.variant_id, inv.quantity;

-- ========================================
-- 3-3. 결과 요약
-- ========================================
-- (위 RETURNING 결과에서 INSERT/UPDATE 건수를 직접 확인)
```

✅ **확인 포인트**: `merge_action()`에 INSERT와 UPDATE가 섞여 나오는지 확인하세요.

---

### 실습 4: CTE — 다단계 매출 분석 파이프라인

```sql
-- ========================================
-- 4-1. 월별 매출 리포트 (4단계 변환)
-- ========================================
WITH monthly_orders AS (
    -- 1단계: 완료 주문만 월별로 정규화
    SELECT
        date_trunc('month', created_at)::date AS order_month,
        user_id,
        total_amount,
        status
    FROM orders
    WHERE status IN ('paid', 'delivered', 'shipping')
      AND created_at >= '2024-01-01'
),
user_monthly AS (
    -- 2단계: 사용자별 월별 집계
    SELECT
        order_month,
        user_id,
        SUM(total_amount) AS user_revenue,
        COUNT(*) AS user_orders
    FROM monthly_orders
    GROUP BY order_month, user_id
),
monthly_summary AS (
    -- 3단계: 월별 전체 집계
    SELECT
        order_month,
        SUM(user_revenue) AS total_revenue,
        SUM(user_orders) AS total_orders,
        COUNT(DISTINCT user_id) AS unique_buyers,
        ROUND(AVG(user_revenue), 2) AS avg_revenue_per_buyer
    FROM user_monthly
    GROUP BY order_month
)
-- 4단계: 전월 대비 변화율 계산
SELECT
    order_month,
    total_revenue,
    total_orders,
    unique_buyers,
    avg_revenue_per_buyer,
    LAG(total_revenue) OVER (ORDER BY order_month) AS prev_month_revenue,
    ROUND(
        (total_revenue - LAG(total_revenue) OVER (ORDER BY order_month))
        / NULLIF(LAG(total_revenue) OVER (ORDER BY order_month), 0) * 100,
        1
    ) AS revenue_change_pct
FROM monthly_summary
ORDER BY order_month;

-- ========================================
-- 4-2. Data-Modifying CTE — 주문 아카이빙 시뮬레이션
-- ========================================

-- 아카이브 테이블 생성
CREATE TABLE orders_archive (LIKE orders INCLUDING ALL);

-- 2024년 1월 cancelled 주문을 아카이브로 이동
WITH archived AS (
    DELETE FROM orders
    WHERE status = 'cancelled'
      AND created_at >= '2024-01-01'
      AND created_at < '2024-02-01'
    RETURNING *
)
INSERT INTO orders_archive
SELECT * FROM archived;

-- 몇 건이 이동했는지 확인
SELECT
    (SELECT count(*) FROM orders_archive) AS archived_count,
    (SELECT count(*) FROM orders WHERE status = 'cancelled'
        AND created_at >= '2024-01-01' AND created_at < '2024-02-01') AS remaining;
-- remaining은 0이어야 함

-- 정리: 아카이브 데이터를 원래 테이블로 복원
INSERT INTO orders SELECT * FROM orders_archive
ON CONFLICT (order_id) DO NOTHING;
DROP TABLE orders_archive;
```

✅ **확인 포인트**: revenue_change_pct가 월별로 계산되는지, 아카이빙 후 remaining이 0인지 확인하세요.

---

### 실습 5: Window Function — 이커머스 분석 쿼리 7종

```sql
-- ========================================
-- 5-1. 일별 매출 + 전일 대비 + 7일 이동평균
-- ========================================
WITH daily AS (
    SELECT
        created_at::date AS order_date,
        SUM(total_amount) AS revenue,
        COUNT(*) AS order_count
    FROM orders
    WHERE status IN ('paid', 'delivered', 'shipping')
      AND created_at >= '2024-06-01'
      AND created_at < '2024-07-01'
    GROUP BY 1
)
SELECT
    order_date,
    revenue,
    order_count,
    LAG(revenue) OVER w AS prev_day_revenue,
    revenue - LAG(revenue) OVER w AS day_change,
    ROUND(AVG(revenue) OVER (
        ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 0) AS moving_avg_7d,
    SUM(revenue) OVER (
        ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_revenue
FROM daily
WINDOW w AS (ORDER BY order_date)
ORDER BY order_date;

-- ========================================
-- 5-2. 고객 등급 분류 (구매 금액 기준 4등급)
-- ========================================
SELECT
    user_id,
    total_spent,
    order_count,
    NTILE(4) OVER (ORDER BY total_spent DESC) AS quartile,
    CASE NTILE(4) OVER (ORDER BY total_spent DESC)
        WHEN 1 THEN 'VIP'
        WHEN 2 THEN 'Gold'
        WHEN 3 THEN 'Silver'
        WHEN 4 THEN 'Bronze'
    END AS tier
FROM (
    SELECT
        user_id,
        SUM(total_amount) AS total_spent,
        COUNT(*) AS order_count
    FROM orders
    WHERE status IN ('paid', 'delivered', 'shipping')
    GROUP BY user_id
) user_stats
ORDER BY total_spent DESC
LIMIT 20;

-- ========================================
-- 5-3. 카테고리별 베스트셀러 Top 3
-- ========================================
SELECT category_name, product_name, total_sold, rank
FROM (
    SELECT
        c.name AS category_name,
        p.name AS product_name,
        SUM(oi.quantity) AS total_sold,
        DENSE_RANK() OVER (
            PARTITION BY c.category_id
            ORDER BY SUM(oi.quantity) DESC
        ) AS rank
    FROM order_items oi
    JOIN product_variants pv ON pv.variant_id = oi.variant_id
    JOIN products p ON p.product_id = pv.product_id
    JOIN categories c ON c.category_id = p.category_id
    GROUP BY c.category_id, c.name, p.product_id, p.name
) ranked
WHERE rank <= 3
ORDER BY category_name, rank;

-- ========================================
-- 5-4. 결제 수단별 월별 비중 변화
-- ========================================
SELECT
    pay_month,
    method,
    method_revenue,
    ROUND(method_revenue / SUM(method_revenue) OVER (PARTITION BY pay_month) * 100, 1)
        AS pct_share,
    RANK() OVER (PARTITION BY pay_month ORDER BY method_revenue DESC) AS rank
FROM (
    SELECT
        date_trunc('month', paid_at)::date AS pay_month,
        method,
        SUM(amount) AS method_revenue
    FROM payments
    WHERE status = 'completed' AND paid_at IS NOT NULL
    GROUP BY 1, 2
) monthly_method
ORDER BY pay_month, rank;

-- ========================================
-- 5-5. 사용자별 주문 간격(일) 분석
-- ========================================
SELECT
    user_id,
    order_date,
    prev_order_date,
    order_date - prev_order_date AS days_between_orders,
    order_number
FROM (
    SELECT
        user_id,
        created_at::date AS order_date,
        LAG(created_at::date) OVER (PARTITION BY user_id ORDER BY created_at) AS prev_order_date,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at) AS order_number
    FROM orders
    WHERE status IN ('paid', 'delivered', 'shipping')
) user_orders
WHERE prev_order_date IS NOT NULL
  AND user_id <= 100  -- 첫 100명만
ORDER BY user_id, order_date
LIMIT 30;

-- ========================================
-- 5-6. 이벤트 로그 중복 제거 (ROW_NUMBER)
-- ========================================

-- 중복 의심 행 확인 (같은 사용자가 같은 이벤트를 1초 내에 여러 번)
WITH potential_dupes AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY user_id, event_type,
                date_trunc('second', created_at)
            ORDER BY created_at DESC
        ) AS rn
    FROM event_logs
    WHERE created_at >= '2024-06-01' AND created_at < '2024-06-02'
)
SELECT
    count(*) FILTER (WHERE rn = 1) AS unique_events,
    count(*) FILTER (WHERE rn > 1) AS duplicate_events,
    count(*) AS total_events
FROM potential_dupes;

-- ========================================
-- 5-7. 상품 리뷰 평점 — 누적 평균 변화 추이
-- ========================================
SELECT
    product_id,
    created_at::date AS review_date,
    rating,
    ROUND(AVG(rating) OVER (
        PARTITION BY product_id
        ORDER BY created_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), 2) AS cumulative_avg_rating,
    COUNT(*) OVER (
        PARTITION BY product_id
        ORDER BY created_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_review_count
FROM reviews
WHERE product_id IN (
    SELECT product_id FROM reviews
    GROUP BY product_id
    HAVING count(*) >= 5  -- 리뷰 5개 이상인 상품만
    LIMIT 3
)
ORDER BY product_id, created_at;
```

---

### 실습 6: LATERAL JOIN — 사용자별 최근 주문 조회

```sql
-- ========================================
-- 6-1. 각 사용자의 최근 주문 3건 조회
-- ========================================
SELECT
    u.user_id,
    u.email,
    u.created_at AS member_since,
    r.order_id,
    r.total_amount,
    r.status,
    r.created_at AS order_date
FROM users u
CROSS JOIN LATERAL (
    SELECT order_id, total_amount, status, created_at
    FROM orders o
    WHERE o.user_id = u.user_id
    ORDER BY o.created_at DESC
    LIMIT 3
) r
WHERE u.user_id <= 10  -- 첫 10명만 조회
ORDER BY u.user_id, r.created_at DESC;

-- ========================================
-- 6-2. LATERAL vs Window Function 성능 비교
-- ========================================

-- 방법 A: LATERAL (인덱스 활용, user_id별 3건만 읽음)
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.user_id, r.*
FROM users u
CROSS JOIN LATERAL (
    SELECT order_id, total_amount, created_at
    FROM orders o
    WHERE o.user_id = u.user_id
    ORDER BY o.created_at DESC
    LIMIT 3
) r
WHERE u.user_id <= 100;

-- 방법 B: Window Function (orders 전체 스캔 후 필터)
EXPLAIN (ANALYZE, BUFFERS)
SELECT user_id, order_id, total_amount, created_at
FROM (
    SELECT
        user_id, order_id, total_amount, created_at,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) AS rn
    FROM orders
    WHERE user_id <= 100
) ranked
WHERE rn <= 3;

-- ========================================
-- 6-3. LEFT JOIN LATERAL — 사용자 통계 (주문 없는 사용자 포함)
-- ========================================
SELECT
    u.user_id,
    u.email,
    COALESCE(stats.total_orders, 0) AS total_orders,
    COALESCE(stats.total_spent, 0) AS total_spent,
    stats.last_order_date,
    CASE
        WHEN stats.total_orders IS NULL THEN '미구매'
        WHEN stats.total_orders >= 10 THEN '충성고객'
        WHEN stats.total_orders >= 3 THEN '일반고객'
        ELSE '신규고객'
    END AS customer_type
FROM users u
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) AS total_orders,
        SUM(total_amount) AS total_spent,
        MAX(created_at)::date AS last_order_date
    FROM orders
    WHERE user_id = u.user_id
      AND status IN ('paid', 'delivered', 'shipping')
) stats ON true
WHERE u.user_id <= 20
ORDER BY total_spent DESC NULLS LAST;
```

✅ **확인 포인트**: 6-2에서 LATERAL이 Index Scan을 사용하고, Window Function 방식이 더 많은 Buffers를 사용하는지 비교하세요.

---

### 실습 7: JSON/JSONB — 상품 메타데이터와 이벤트 로그 분석

```sql
-- ========================================
-- 7-1. products.metadata JSONB 탐색
-- ========================================

-- metadata 구조 확인 (샘플)
SELECT product_id, name, jsonb_pretty(metadata)
FROM products LIMIT 3;
-- metadata 예: {"brand": "삼성", "tags": ["인기", "추천"], "weight_g": 1234}

-- 브랜드별 상품 수 및 평균 가격
SELECT
    metadata ->> 'brand' AS brand,
    COUNT(*) AS product_count,
    ROUND(AVG(base_price), 0) AS avg_price,
    ROUND(MIN(base_price), 0) AS min_price,
    ROUND(MAX(base_price), 0) AS max_price
FROM products
GROUP BY metadata ->> 'brand'
ORDER BY product_count DESC;

-- 특정 태그를 가진 상품 검색 (@> containment 연산자 — GIN 인덱스 활용)
SELECT product_id, name, base_price, metadata -> 'tags' AS tags
FROM products
WHERE metadata -> 'tags' @> '["프리미엄"]'
LIMIT 10;

-- 위 쿼리가 GIN 인덱스를 사용하는지 확인
EXPLAIN (ANALYZE)
SELECT product_id, name FROM products
WHERE metadata -> 'tags' @> '["프리미엄"]';

-- ========================================
-- 7-2. product_variants.attributes JSONB 분석
-- ========================================

-- 색상별 변형 수 및 평균 가격
SELECT
    attributes ->> 'color' AS color,
    COUNT(*) AS variant_count,
    ROUND(AVG(price), 0) AS avg_price
FROM product_variants
GROUP BY attributes ->> 'color'
ORDER BY variant_count DESC;

-- ========================================
-- 7-3. event_logs.payload JSONB 분석
-- ========================================

-- payload 구조 확인
SELECT event_type, jsonb_pretty(payload)
FROM event_logs LIMIT 3;
-- payload 예: {"page": "/products", "device": "mobile", "duration_ms": 12345}

-- 디바이스별 이벤트 분포
SELECT
    payload ->> 'device' AS device,
    event_type,
    COUNT(*) AS cnt
FROM event_logs
WHERE created_at >= '2024-06-01' AND created_at < '2024-07-01'
GROUP BY payload ->> 'device', event_type
ORDER BY device, cnt DESC;

-- 페이지별 평균 체류 시간 (duration_ms)
SELECT
    payload ->> 'page' AS page,
    COUNT(*) AS views,
    ROUND(AVG((payload ->> 'duration_ms')::INT), 0) AS avg_duration_ms,
    ROUND(AVG((payload ->> 'duration_ms')::INT) / 1000.0, 1) AS avg_duration_sec
FROM event_logs
WHERE event_type = 'page_view'
  AND created_at >= '2024-06-01' AND created_at < '2024-07-01'
GROUP BY payload ->> 'page'
ORDER BY views DESC;

-- ========================================
-- 7-4. JSON_TABLE (PG17) — 주문의 address_snapshot 변환
-- ========================================

-- address_snapshot 구조 확인
SELECT order_id, jsonb_pretty(address_snapshot)
FROM orders LIMIT 3;
-- 예: {"address": "서울시 테스트구", "recipient": "user12345"}

-- JSON_TABLE로 관계형 변환
SELECT jt.*
FROM orders o,
     JSON_TABLE(
         o.address_snapshot,
         '$'
         COLUMNS (
             recipient TEXT PATH '$.recipient',
             address   TEXT PATH '$.address'
         )
     ) AS jt
WHERE o.order_id <= 10;

-- ========================================
-- 7-5. 관계형 → JSON 빌드 (API 응답 구성)
-- ========================================

-- 사용자 프로필 + 최근 주문을 JSON 문서로 구성
SELECT jsonb_build_object(
    'user_id', u.user_id,
    'email', u.email,
    'username', u.username,
    'recent_orders', (
        SELECT jsonb_agg(
            jsonb_build_object(
                'order_id', o.order_id,
                'total', o.total_amount,
                'status', o.status,
                'date', o.created_at::date
            ) ORDER BY o.created_at DESC
        )
        FROM (
            SELECT * FROM orders
            WHERE user_id = u.user_id
            ORDER BY created_at DESC
            LIMIT 5
        ) o
    )
) AS user_profile
FROM users u
WHERE u.user_id = 1;
```

---

### 실습 8: 파티셔닝 — event_logs 파티션 탐색

```sql
-- ========================================
-- 8-1. 기존 파티션 구조 확인
-- ========================================

-- 파티션 목록
SELECT
    parent.relname AS parent_table,
    child.relname AS partition_name,
    pg_get_expr(child.relpartbound, child.oid) AS partition_range,
    pg_size_pretty(pg_relation_size(child.oid)) AS size
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child ON pg_inherits.inhrelid = child.oid
WHERE parent.relname = 'event_logs'
ORDER BY child.relname;

-- ========================================
-- 8-2. 파티션 프루닝 확인
-- ========================================

-- 2024년 6월 데이터만 조회 → 해당 파티션만 스캔되는지 확인
EXPLAIN (ANALYZE)
SELECT count(*) FROM event_logs
WHERE created_at >= '2024-06-01' AND created_at < '2024-07-01';
-- "Partitions selected: 1 (out of N)" 확인

-- 여러 달 조회 → 해당 파티션들만 스캔
EXPLAIN (ANALYZE)
SELECT count(*) FROM event_logs
WHERE created_at >= '2024-06-01' AND created_at < '2024-09-01';
-- "Partitions selected: 3" 확인

-- ========================================
-- 8-3. 새 파티션 추가 (무중단 적재 시뮬레이션)
-- ========================================

-- 독립 테이블로 먼저 생성
CREATE TABLE event_logs_2025_07 (
    LIKE event_logs INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES
);

-- CHECK 제약 추가 (ATTACH 시 검증 스캔 생략)
ALTER TABLE event_logs_2025_07
    ADD CONSTRAINT chk_2025_07
    CHECK (created_at >= '2025-07-01' AND created_at < '2025-08-01');

-- 테스트 데이터 적재
INSERT INTO event_logs_2025_07 (user_id, event_type, payload, created_at)
SELECT
    floor(random() * 100000 + 1)::BIGINT,
    (ARRAY['page_view','product_click','add_to_cart','purchase'])[floor(random()*4+1)::int],
    jsonb_build_object('page', '/', 'device', 'mobile'),
    '2025-07-01'::TIMESTAMPTZ + random() * INTERVAL '30 days'
FROM generate_series(1, 10000);

-- 파티션으로 붙이기
ALTER TABLE event_logs ATTACH PARTITION event_logs_2025_07
    FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');

-- 확인: 새 파티션의 데이터가 조회되는지
SELECT count(*) FROM event_logs
WHERE created_at >= '2025-07-01' AND created_at < '2025-08-01';

-- ========================================
-- 8-4. 파티션 분리 (데이터 보관/삭제)
-- ========================================

-- DETACH (PG14+ CONCURRENTLY 가능)
ALTER TABLE event_logs DETACH PARTITION event_logs_2025_07;

-- 분리된 테이블은 독립적으로 존재 → 백업 후 삭제 가능
SELECT count(*) FROM event_logs_2025_07;  -- 여전히 조회 가능
DROP TABLE event_logs_2025_07;
```

✅ **확인 포인트**: 8-2에서 EXPLAIN 출력에 "Partitions removed" 또는 "Partitions selected: 1"이 나오는지 확인하세요.

---

### 실습 9: Materialized View — 대시보드용 사전 집계

```sql
-- ========================================
-- 9-1. 카테고리별 월별 매출 Materialized View 생성
-- ========================================
CREATE MATERIALIZED VIEW mv_category_monthly_sales AS
SELECT
    c.category_id,
    c.name AS category_name,
    date_trunc('month', o.created_at)::date AS sale_month,
    COUNT(DISTINCT o.order_id) AS order_count,
    SUM(oi.quantity) AS units_sold,
    SUM(oi.subtotal) AS revenue
FROM order_items oi
JOIN orders o ON o.order_id = oi.order_id
JOIN product_variants pv ON pv.variant_id = oi.variant_id
JOIN products p ON p.product_id = pv.product_id
JOIN categories c ON c.category_id = p.category_id
WHERE o.status IN ('paid', 'delivered', 'shipping')
GROUP BY c.category_id, c.name, date_trunc('month', o.created_at)
WITH DATA;

-- CONCURRENTLY 갱신을 위한 UNIQUE 인덱스
CREATE UNIQUE INDEX idx_mv_cat_monthly
    ON mv_category_monthly_sales (category_id, sale_month);

-- 조회용 인덱스
CREATE INDEX idx_mv_cat_monthly_month
    ON mv_category_monthly_sales (sale_month);

-- ========================================
-- 9-2. 대시보드 쿼리 (매우 빠름!)
-- ========================================

-- 카테고리별 최근 3개월 매출 추이
SELECT
    category_name,
    sale_month,
    revenue,
    ROUND(revenue / SUM(revenue) OVER (PARTITION BY sale_month) * 100, 1) AS pct_share
FROM mv_category_monthly_sales
WHERE sale_month >= '2024-10-01'
ORDER BY sale_month, revenue DESC;

-- ========================================
-- 9-3. 원본 쿼리 vs MV 성능 비교
-- ========================================

-- MV 조회 (즉시 응답)
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM mv_category_monthly_sales
WHERE sale_month = '2024-06-01';

-- 원본 테이블 JOIN (느림)
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, SUM(oi.subtotal)
FROM order_items oi
JOIN orders o ON o.order_id = oi.order_id
JOIN product_variants pv ON pv.variant_id = oi.variant_id
JOIN products p ON p.product_id = pv.product_id
JOIN categories c ON c.category_id = p.category_id
WHERE o.status IN ('paid', 'delivered', 'shipping')
  AND date_trunc('month', o.created_at) = '2024-06-01'
GROUP BY c.name;

-- ========================================
-- 9-4. CONCURRENTLY 갱신 (조회 차단 없음)
-- ========================================
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_category_monthly_sales;

-- 정리
-- DROP MATERIALIZED VIEW mv_category_monthly_sales;
```

✅ **확인 포인트**: 9-3에서 MV 조회가 원본 쿼리보다 실행 시간이 훨씬 짧은지 비교하세요.

---

### 실습 10: generate_series + 갭 채우기

```sql
-- ========================================
-- 10-1. 2024년 6월 일별 주문 현황 (0건인 날도 표시)
-- ========================================
SELECT
    d.day,
    COALESCE(stats.order_count, 0) AS order_count,
    COALESCE(stats.revenue, 0) AS revenue
FROM generate_series(
    '2024-06-01'::date,
    '2024-06-30'::date,
    INTERVAL '1 day'
) AS d(day)
LEFT JOIN (
    SELECT
        created_at::date AS order_date,
        COUNT(*) AS order_count,
        SUM(total_amount) AS revenue
    FROM orders
    WHERE status IN ('paid', 'delivered', 'shipping')
      AND created_at >= '2024-06-01'
      AND created_at < '2024-07-01'
    GROUP BY 1
) stats ON stats.order_date = d.day
ORDER BY d.day;

-- ========================================
-- 10-2. 시간대별 이벤트 히트맵 (24시간)
-- ========================================
SELECT
    to_char(h.hour, 'HH24:00') AS time_slot,
    COALESCE(e.event_count, 0) AS events,
    REPEAT('█', LEAST(COALESCE(e.event_count, 0) / 50, 50)) AS bar
FROM generate_series(0, 23) AS h(hour)
LEFT JOIN (
    SELECT
        EXTRACT(HOUR FROM created_at)::INT AS hour,
        COUNT(*) AS event_count
    FROM event_logs
    WHERE created_at >= '2024-06-15' AND created_at < '2024-06-16'
    GROUP BY 1
) e ON e.hour = h.hour
ORDER BY h.hour;

-- ========================================
-- 10-3. 카테고리 × 월 매트릭스 (크로스 조인으로 빈 칸 채우기)
-- ========================================
SELECT
    c.name AS category,
    m.month,
    COALESCE(s.order_count, 0) AS orders,
    COALESCE(s.revenue, 0) AS revenue
FROM (
    SELECT category_id, name FROM categories WHERE depth = 1
) c
CROSS JOIN generate_series(
    '2024-01-01'::date, '2024-06-01'::date, INTERVAL '1 month'
) AS m(month)
LEFT JOIN (
    SELECT
        p.category_id,
        date_trunc('month', o.created_at)::date AS month,
        COUNT(*) AS order_count,
        SUM(oi.subtotal) AS revenue
    FROM order_items oi
    JOIN orders o ON o.order_id = oi.order_id
    JOIN product_variants pv ON pv.variant_id = oi.variant_id
    JOIN products p ON p.product_id = pv.product_id
    WHERE o.status IN ('paid', 'delivered', 'shipping')
    GROUP BY p.category_id, date_trunc('month', o.created_at)
) s ON s.category_id = c.category_id AND s.month = m.month
ORDER BY c.name, m.month;
```

---

### 실습 11: 배치 처리 + Keyset 페이지네이션

```sql
-- ========================================
-- 11-1. 오래된 이벤트 로그 청크 삭제 시뮬레이션
-- ========================================

-- 삭제 대상 건수 먼저 확인
SELECT count(*) FROM event_logs
WHERE created_at < '2024-04-01';

-- 1000건씩 청크 삭제 (1회 실행)
WITH batch AS (
    SELECT created_at, event_id
    FROM event_logs
    WHERE created_at < '2024-04-01'
    ORDER BY created_at, event_id
    LIMIT 1000
)
DELETE FROM event_logs
WHERE (created_at, event_id) IN (SELECT created_at, event_id FROM batch);
-- 실제로는 반복 실행하지만, 실습에서는 1회만 실행하여 원리 확인

-- ========================================
-- 11-2. Keyset 페이지네이션 vs OFFSET 비교
-- ========================================

-- OFFSET 방식 (깊은 페이지에서 느림)
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, user_id, total_amount, created_at
FROM orders
ORDER BY created_at, order_id
LIMIT 20 OFFSET 400000;

-- Keyset 방식 (항상 빠름)
-- 먼저 400000번째 행의 커서 값을 구함
SELECT created_at, order_id
FROM orders
ORDER BY created_at, order_id
LIMIT 1 OFFSET 399999;
-- 이 값을 아래에 넣으세요 (예시)

-- 커서를 이용한 조회 (실제 값으로 대체)
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, user_id, total_amount, created_at
FROM orders
WHERE (created_at, order_id) > ('2024-08-15 12:00:00+00', 400000)  -- 실제 커서값 대입
ORDER BY created_at, order_id
LIMIT 20;

-- ========================================
-- 11-3. Advisory Lock으로 동시 작업 방지
-- ========================================

-- 락 획득 시도 (ETL 작업 시작 전)
SELECT pg_try_advisory_lock(hashtext('monthly_report_etl')) AS acquired;
-- true면 획득 성공, false면 이미 다른 세션이 실행 중

-- (다른 터미널에서 같은 명령 실행하면 false 반환)

-- 락 해제
SELECT pg_advisory_unlock(hashtext('monthly_report_etl'));
```

---

### 실습 12: EXPLAIN ANALYZE — 실제 쿼리 최적화

```sql
-- ========================================
-- 12-1. Seq Scan 발견 → 인덱스 추가
-- ========================================

-- 결제 방식별 조회 (인덱스 없는 컬럼)
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM payments
WHERE method = 'card' AND status = 'completed'
LIMIT 100;
-- Seq Scan 확인

-- 인덱스 추가
CREATE INDEX idx_payments_method_status ON payments (method, status);

-- 다시 실행
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM payments
WHERE method = 'card' AND status = 'completed'
LIMIT 100;
-- Index Scan 또는 Bitmap Index Scan 확인

-- 정리
DROP INDEX idx_payments_method_status;

-- ========================================
-- 12-2. JOIN 방식 관찰
-- ========================================

-- 소량 결과 JOIN (Nested Loop 예상)
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.order_id, u.email, o.total_amount
FROM orders o
JOIN users u ON u.user_id = o.user_id
WHERE o.order_id = 12345;

-- 대량 결과 JOIN (Hash Join 예상)
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.status, COUNT(*), SUM(o.total_amount)
FROM orders o
JOIN users u ON u.user_id = o.user_id
WHERE u.created_at >= '2024-06-01' AND u.created_at < '2024-07-01'
GROUP BY o.status;

-- ========================================
-- 12-3. 파티션 프루닝 효과 측정
-- ========================================

-- 프루닝 활성화 (기본값)
SET enable_partition_pruning = on;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM event_logs
WHERE created_at >= '2024-06-01' AND created_at < '2024-07-01';

-- 프루닝 비활성화 (비교용)
SET enable_partition_pruning = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM event_logs
WHERE created_at >= '2024-06-01' AND created_at < '2024-07-01';

-- 원복
SET enable_partition_pruning = on;
```

✅ **확인 포인트**: 프루닝 ON/OFF에서 스캔 파티션 수와 Buffers 차이를 비교하세요.

---

### 실습 13: 카탈로그 쿼리 — 이 DB의 현재 상태 파악

```sql
-- ========================================
-- 13-1. 테이블별 크기 랭킹
-- ========================================
SELECT
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    pg_size_pretty(pg_relation_size(relid)) AS data_size,
    pg_size_pretty(pg_indexes_size(relid)) AS index_size,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 15;

-- ========================================
-- 13-2. 인덱스 사용 현황 (미사용 인덱스 찾기)
-- ========================================
SELECT
    schemaname || '.' || indexrelname AS index_name,
    relname AS table_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size,
    idx_scan AS scan_count,
    CASE
        WHEN idx_scan = 0 THEN '⚠️ 미사용'
        WHEN idx_scan < 10 THEN '🟡 거의 안 씀'
        ELSE '✅ 활발'
    END AS usage_status
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY idx_scan ASC, pg_relation_size(indexrelid) DESC;

-- ========================================
-- 13-3. Dead Tuple 현황 + VACUUM 필요 여부
-- ========================================
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 100
ORDER BY dead_pct DESC;

-- ========================================
-- 13-4. 전체 DB 캐시 적중률
-- ========================================
SELECT
    sum(heap_blks_read) AS heap_read,
    sum(heap_blks_hit) AS heap_hit,
    ROUND(
        sum(heap_blks_hit) * 100.0 / NULLIF(sum(heap_blks_hit) + sum(heap_blks_read), 0),
        2
    ) AS cache_hit_ratio
FROM pg_statio_user_tables;
-- 99% 이상이면 양호

-- ========================================
-- 13-5. pg_stat_statements — 느린 쿼리 Top 10
-- ========================================
SELECT
    calls,
    ROUND(total_exec_time::numeric, 0) AS total_ms,
    ROUND(mean_exec_time::numeric, 1) AS avg_ms,
    rows,
    LEFT(query, 80) AS query_preview
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'ecommerce')
ORDER BY total_exec_time DESC
LIMIT 10;
```

---

### 실습 14: Recursive CTE — 카테고리 계층 탐색

```sql
-- ========================================
-- 14-1. 전체 카테고리 트리 (breadcrumb 생성)
-- ========================================
WITH RECURSIVE cat_tree AS (
    -- 루트 카테고리
    SELECT
        category_id,
        name,
        parent_id,
        name::TEXT AS breadcrumb,
        depth,
        ARRAY[category_id] AS path
    FROM categories
    WHERE parent_id IS NULL

    UNION ALL

    -- 자식 카테고리
    SELECT
        c.category_id,
        c.name,
        c.parent_id,
        ct.breadcrumb || ' > ' || c.name,
        c.depth,
        ct.path || c.category_id
    FROM categories c
    JOIN cat_tree ct ON c.parent_id = ct.category_id
)
SELECT
    category_id,
    REPEAT('  ', depth) || name AS indented_name,
    breadcrumb,
    depth
FROM cat_tree
ORDER BY path;

-- ========================================
-- 14-2. 특정 카테고리의 모든 하위 상품 수 집계
-- ========================================
WITH RECURSIVE subcategories AS (
    SELECT category_id FROM categories WHERE name = '전자제품'
    UNION ALL
    SELECT c.category_id
    FROM categories c
    JOIN subcategories sc ON c.parent_id = sc.category_id
)
SELECT
    c.name AS category_name,
    COUNT(p.product_id) AS product_count,
    ROUND(AVG(p.base_price), 0) AS avg_price
FROM subcategories sc
JOIN categories c ON c.category_id = sc.category_id
LEFT JOIN products p ON p.category_id = sc.category_id
GROUP BY c.category_id, c.name
ORDER BY product_count DESC;
```

---

### 실습 15: 종합 시나리오 — 일별 ETL 파이프라인

이 실습은 여러 패턴을 조합하여 실제 ETL 파이프라인을 시뮬레이션합니다.

```sql
-- ============================================================
-- 시나리오: 매일 실행되는 "일별 판매 요약" ETL 파이프라인
-- 대상 날짜: 2024-06-15
-- ============================================================

-- 1단계: 요약 테이블 생성 (최초 1회)
CREATE TABLE IF NOT EXISTS daily_sales_summary (
    summary_date    DATE NOT NULL,
    category_id     INT NOT NULL,
    category_name   TEXT NOT NULL,
    order_count     INT NOT NULL,
    units_sold      BIGINT NOT NULL,
    revenue         NUMERIC(15,2) NOT NULL,
    avg_order_value NUMERIC(12,2) NOT NULL,
    unique_buyers   INT NOT NULL,
    top_product     TEXT,
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (summary_date, category_id)
);

-- 2단계: CTE 파이프라인으로 데이터 변환 + Upsert
WITH target_orders AS (
    -- 필터링: 해당 날짜의 유효 주문
    SELECT o.order_id, o.user_id, o.total_amount, o.created_at
    FROM orders o
    WHERE o.status IN ('paid', 'delivered', 'shipping')
      AND o.created_at::date = '2024-06-15'
),
order_details AS (
    -- 주문 상세 JOIN
    SELECT
        t.order_id,
        t.user_id,
        p.category_id,
        c.name AS category_name,
        p.name AS product_name,
        oi.quantity,
        oi.subtotal
    FROM target_orders t
    JOIN order_items oi ON oi.order_id = t.order_id
    JOIN product_variants pv ON pv.variant_id = oi.variant_id
    JOIN products p ON p.product_id = pv.product_id
    JOIN categories c ON c.category_id = p.category_id
),
category_summary AS (
    -- 카테고리별 집계
    SELECT
        category_id,
        category_name,
        COUNT(DISTINCT order_id) AS order_count,
        SUM(quantity) AS units_sold,
        SUM(subtotal) AS revenue,
        ROUND(SUM(subtotal) / NULLIF(COUNT(DISTINCT order_id), 0), 2) AS avg_order_value,
        COUNT(DISTINCT user_id) AS unique_buyers
    FROM order_details
    GROUP BY category_id, category_name
),
top_products AS (
    -- 카테고리별 최고 매출 상품 (LATERAL 대안: DISTINCT ON)
    SELECT DISTINCT ON (category_id)
        category_id,
        product_name
    FROM order_details
    GROUP BY category_id, product_name
    ORDER BY category_id, SUM(subtotal) DESC
)
-- Upsert: 이미 해당 날짜 요약이 있으면 갱신
INSERT INTO daily_sales_summary
    (summary_date, category_id, category_name, order_count, units_sold,
     revenue, avg_order_value, unique_buyers, top_product, updated_at)
SELECT
    '2024-06-15'::date,
    cs.category_id,
    cs.category_name,
    cs.order_count,
    cs.units_sold,
    cs.revenue,
    cs.avg_order_value,
    cs.unique_buyers,
    tp.product_name,
    NOW()
FROM category_summary cs
LEFT JOIN top_products tp ON tp.category_id = cs.category_id
ON CONFLICT (summary_date, category_id) DO UPDATE SET
    order_count = EXCLUDED.order_count,
    units_sold = EXCLUDED.units_sold,
    revenue = EXCLUDED.revenue,
    avg_order_value = EXCLUDED.avg_order_value,
    unique_buyers = EXCLUDED.unique_buyers,
    top_product = EXCLUDED.top_product,
    updated_at = NOW();

-- 3단계: 결과 확인
SELECT
    summary_date,
    category_name,
    order_count,
    units_sold,
    revenue,
    avg_order_value,
    unique_buyers,
    top_product
FROM daily_sales_summary
WHERE summary_date = '2024-06-15'
ORDER BY revenue DESC;

-- 4단계: 여러 날짜에 대해 반복 실행해보기 (갭 채우기 포함)
-- generate_series로 한 달치를 한번에 확인
SELECT
    d.day,
    COALESCE(s.total_revenue, 0) AS revenue,
    COALESCE(s.total_orders, 0) AS orders
FROM generate_series('2024-06-01'::date, '2024-06-30'::date, '1 day') AS d(day)
LEFT JOIN (
    SELECT summary_date, SUM(revenue) AS total_revenue, SUM(order_count) AS total_orders
    FROM daily_sales_summary
    GROUP BY summary_date
) s ON s.summary_date = d.day
ORDER BY d.day;

-- 정리
-- DROP TABLE daily_sales_summary;
```

✅ **확인 포인트**:
- CTE 4단계가 순차적으로 처리되는 구조를 이해했는지
- ON CONFLICT로 같은 쿼리를 여러 번 실행해도 안전한지 (idempotent)
- generate_series로 빈 날짜가 0으로 채워지는지

---

## PG17 신기능 요약 (데이터 엔지니어링 관련)

| 기능 | 설명 | 관련 섹션 |
|------|------|----------|
| `JSON_TABLE` | JSON → 관계형 테이블 변환 (SQL/JSON 표준) | [7. JSON/JSONB](#7-jsonjsonb-처리) |
| `MERGE ... RETURNING` | MERGE 결과를 `merge_action()`으로 추적 | [3. MERGE](#3-merge--차세대-동기화-pg15-returning-pg17) |
| `COPY ON_ERROR ignore` | 타입 오류 행을 건너뛰고 적재 | [1. COPY](#1-copy--대량-데이터-적재추출) |
| `COPY LOG_VERBOSITY verbose` | 건너뛴 행의 상세 로그 | [1. COPY](#1-copy--대량-데이터-적재추출) |
| 파티션 프루닝 개선 | OR 조건 등 복잡한 WHERE 절에서도 프루닝 적용 | [8. 파티셔닝](#8-파티셔닝--대규모-테이블-관리) |
| CTE 스캔 최적화 | MATERIALIZED CTE 스캔의 실행 계획 개선 | [4. CTE](#4-cte--복잡한-변환-파이프라인) |

---

## 참고 출처

### PostgreSQL 17 공식 문서
- [COPY](https://www.postgresql.org/docs/17/sql-copy.html) | [INSERT](https://www.postgresql.org/docs/17/sql-insert.html) | [MERGE](https://www.postgresql.org/docs/17/sql-merge.html)
- [WITH Queries (CTE)](https://www.postgresql.org/docs/17/queries-with.html) | [Window Functions](https://www.postgresql.org/docs/17/functions-window.html)
- [JSON Functions](https://www.postgresql.org/docs/17/functions-json.html) | [Table Partitioning](https://www.postgresql.org/docs/17/ddl-partitioning.html)
- [CREATE MATERIALIZED VIEW](https://www.postgresql.org/docs/17/sql-creatematerializedview.html)
- [EXPLAIN](https://www.postgresql.org/docs/17/sql-explain.html) | [Monitoring Stats](https://www.postgresql.org/docs/17/monitoring-stats.html)
- [postgres_fdw](https://www.postgresql.org/docs/17/postgres-fdw.html) | [file_fdw](https://www.postgresql.org/docs/17/file-fdw.html)
- [Constraints](https://www.postgresql.org/docs/17/ddl-constraints.html) | [pg_stat_statements](https://www.postgresql.org/docs/17/pgstatstatements.html)
- [Populating a Database (Performance)](https://www.postgresql.org/docs/17/populate.html)

### 커뮤니티 자료
- [Crunchy Data: LATERAL Joins](https://www.crunchydata.com/blog/iterators-in-postgresql-with-lateral-joins)
- [Citus Data: Five Ways to Paginate](https://www.citusdata.com/blog/2016/03/30/five-ways-to-paginate/)
- [pganalyze: EXPLAIN ANALYZE Needs BUFFERS](https://postgres.ai/blog/20220106-explain-analyze-needs-buffers-to-improve-the-postgres-query-optimization-process)
- [pganalyze: GIN Index Performance](https://pganalyze.com/blog/gin-index)
- [Haki Benita: Be Careful With CTE](https://hakibenita.com/be-careful-with-cte-in-postgre-sql)
- [Cybertec: Exclusion Constraints](https://www.cybertec-postgresql.com/en/postgresql-exclusion-constraints-beyond-unique/)
- [EXPLAIN Visualizer (Dalibo)](https://explain.dalibo.com/)
