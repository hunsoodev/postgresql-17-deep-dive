# 인덱스 심화

## 한줄 요약

인덱스는 "책의 목차"처럼 데이터를 빠르게 찾을 수 있게 해주는 보조 자료 구조로, PostgreSQL은 B-tree, Hash, GiST, SP-GiST, GIN, BRIN 등 다양한 인덱스 타입을 지원하며 각각 특정 데이터 타입과 쿼리 패턴에 최적화되어 있습니다.

## 왜 알아야 하는가

### 실무에서 마주하는 문제들

1. **느린 검색 쿼리**
   ```sql
   -- 100만 건 테이블에서 이메일 검색
   SELECT * FROM users WHERE email = 'alice@example.com';
   -- 인덱스 없음: 10초
   -- 인덱스 있음: 0.001초
   ```

2. **잘못된 인덱스 설계**
   ```sql
   -- 멀티컬럼 인덱스 순서 실수
   CREATE INDEX idx_wrong ON orders(status, user_id);
   -- 이 쿼리는 인덱스를 못 씀:
   SELECT * FROM orders WHERE user_id = 100;
   ```

3. **인덱스 Bloat**
   - 인덱스가 테이블보다 큰 경우
   - UPDATE/DELETE로 인한 인덱스 단편화
   - 성능 저하 및 디스크 낭비

4. **잘못된 인덱스 타입 선택**
   ```sql
   -- JSONB 컬럼에 B-tree 인덱스 (비효율)
   CREATE INDEX idx_bad ON products USING btree(metadata);
   -- GIN 인덱스가 더 적합
   CREATE INDEX idx_good ON products USING gin(metadata);
   ```

5. **과도한 인덱스**
   - 쓰기 성능 저하 (INSERT/UPDATE/DELETE 시 모든 인덱스 갱신)
   - 디스크 공간 낭비
   - VACUUM 시간 증가

### 인덱스를 이해하지 못하면?

- Seq Scan으로 인한 느린 쿼리
- 불필요한 인덱스로 쓰기 성능 저하
- 잘못된 실행 계획으로 타임아웃
- 디스크 I/O 증가로 전체 시스템 성능 저하
- 인덱스 유지보수 비용 증가

## 핵심 개념

### 1. 인덱스란?

**비유: 책의 목차**

책에서 특정 주제를 찾을 때:
- 목차 없음: 처음부터 끝까지 읽기 (Seq Scan)
- 목차 있음: 목차에서 페이지 번호 찾고 바로 이동 (Index Scan)

**기술적 정의:**
- 테이블 데이터의 부분 집합을 정렬된 구조로 저장
- 검색 키 → 행 위치(CTID) 매핑
- 별도의 파일로 저장 (테이블과 독립적)

**인덱스 생성:**

```sql
-- 기본 B-tree 인덱스
CREATE INDEX idx_users_email ON users(email);

-- 인덱스 타입 명시
CREATE INDEX idx_users_email_btree ON users USING btree(email);

-- 복합 인덱스
CREATE INDEX idx_orders_user_status ON orders(user_id, status);

-- 표현식 인덱스
CREATE INDEX idx_users_lower_email ON users(LOWER(email));

-- 부분 인덱스
CREATE INDEX idx_orders_pending ON orders(user_id)
WHERE status = 'pending';

-- 커버링 인덱스 (INCLUDE)
CREATE INDEX idx_users_email_inc ON users(email) INCLUDE (username, created_at);
```

### 2. 인덱스 스캔 방식

**1) Sequential Scan (전체 테이블 스캔)**

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE random() < 0.5;

-- Seq Scan on users (cost=0.00..1234.00 rows=5000 width=100)
-- Buffers: shared hit=1000
-- Planning Time: 0.123 ms
-- Execution Time: 45.678 ms
```

**특징:**
- 테이블의 모든 페이지를 순차적으로 읽음
- 인덱스 사용 안 함
- 소량 데이터 또는 대부분의 행이 필요할 때 효율적

**2) Index Scan**

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE email = 'alice@example.com';

-- Index Scan using idx_users_email on users
-- (cost=0.42..8.44 rows=1 width=100)
-- Buffers: shared hit=4
-- Execution Time: 0.123 ms
```

**동작 과정:**
1. 인덱스에서 'alice@example.com' 검색
2. CTID (페이지 번호, 오프셋) 획득
3. 테이블 페이지에서 실제 행 읽기

**3) Index Only Scan**

```sql
-- Covering Index 생성
CREATE INDEX idx_users_email_username ON users(email) INCLUDE (username);

EXPLAIN (ANALYZE, BUFFERS)
SELECT email, username FROM users WHERE email = 'alice@example.com';

-- Index Only Scan using idx_users_email_username on users
-- Heap Fetches: 0
-- Buffers: shared hit=3
-- Execution Time: 0.056 ms
```

**특징:**
- 인덱스만으로 쿼리 응답 (테이블 접근 안 함)
- Visibility Map 필요 (VACUUM으로 설정)
- 가장 빠른 스캔 방식

**4) Bitmap Scan**

```sql
-- 여러 조건 OR
EXPLAIN (ANALYZE)
SELECT * FROM orders
WHERE user_id = 100 OR status = 'pending';

-- BitmapOr
--   -> Bitmap Index Scan on idx_orders_user
--   -> Bitmap Index Scan on idx_orders_status
-- -> Bitmap Heap Scan on orders
```

**동작 과정:**
1. 각 인덱스에서 비트맵 생성
2. 비트맵 OR/AND 연산
3. 결과 비트맵으로 테이블 스캔

**장점:**
- 여러 인덱스 조합 가능
- 랜덤 I/O를 순차 I/O로 변환 (페이지 정렬)

## OS/파일시스템 관점

### 1. Index Scan = 랜덤 I/O, Seq Scan = 순차 I/O

**Sequential I/O (순차 읽기):**

```
테이블 파일 (순차 읽기):
[페이지0][페이지1][페이지2][페이지3]...
   ↓      ↓      ↓      ↓
디스크 헤드가 한 방향으로 이동 (빠름)

HDD: ~100-200 MB/s
SSD: ~500-3000 MB/s
```

**Random I/O (랜덤 읽기):**

```
Index Scan:
인덱스 → 페이지5 → 페이지2 → 페이지9 → 페이지1
         ↑       ↑       ↑       ↑
   디스크 헤드가 이동 (느림)

HDD: ~100-200 IOPS (매우 느림!)
SSD: ~50,000-500,000 IOPS (빠름)
```

**random_page_cost 파라미터:**

```sql
-- HDD 환경 (기본값)
SHOW random_page_cost;
-- 4.0
-- 의미: 랜덤 I/O는 순차 I/O의 4배 비용

-- SSD 환경
ALTER DATABASE ecommerce SET random_page_cost = 1.1;
-- SSD는 랜덤/순차 차이가 적음
-- 인덱스 스캔이 더 자주 선택됨
```

**실습: random_page_cost 영향**

```sql
-- HDD 설정 (random_page_cost=4)
SET random_page_cost = 4;
EXPLAIN SELECT * FROM orders WHERE user_id = 100;
-- Seq Scan (인덱스 안 씀)

-- SSD 설정
SET random_page_cost = 1.1;
EXPLAIN SELECT * FROM orders WHERE user_id = 100;
-- Index Scan (인덱스 씀)
```

### 2. OS Page Cache 히트율

PostgreSQL은 OS의 페이지 캐시를 활용합니다.

```
메모리 계층:
┌──────────────────────────┐
│ PostgreSQL Shared Buffer │ ← 설정: shared_buffers (예: 4GB)
├──────────────────────────┤
│ OS Page Cache            │ ← 커널이 자동 관리
├──────────────────────────┤
│ Disk                     │ ← 실제 I/O 발생
└──────────────────────────┘
```

**캐시 히트율 확인:**

```sql
-- Shared Buffer 히트율
SELECT
    sum(heap_blks_read) AS heap_read,
    sum(heap_blks_hit) AS heap_hit,
    sum(heap_blks_hit) * 100.0 /
        nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0) AS hit_ratio
FROM pg_stattuple;
-- hit_ratio > 99% 권장

-- 테이블별 캐시 상태
SELECT
    c.relname,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS size,
    pg_buffercache.count AS cached_blocks,
    pg_buffercache.count * 8192 AS cached_bytes
FROM pg_class c
LEFT JOIN (
    SELECT relation, count(*)
    FROM pg_buffercache
    GROUP BY relation
) pg_buffercache ON c.oid = pg_buffercache.relation
WHERE c.relname = 'users';
```

**인덱스 캐싱 효과:**

- 핫 인덱스 (자주 사용): 대부분 메모리에 존재 → 빠름
- 콜드 인덱스 (가끔 사용): 디스크 I/O 필요 → 느림
- 인덱스는 테이블보다 작아 캐시에 오래 유지

### 3. 인덱스 파일 구조

```bash
# PostgreSQL 데이터 디렉토리
cd $PGDATA/base/<database_oid>

# 테이블과 인덱스 파일
ls -lh
# 16384       ← users 테이블
# 16385       ← users_pkey (PK 인덱스)
# 16386       ← idx_users_email (인덱스)
# 16386_fsm   ← Free Space Map
```

**파일 크기 비교:**

```sql
SELECT
    indexrelname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    pg_size_pretty(pg_relation_size(indrelid)) AS table_size,
    round(100.0 * pg_relation_size(indexrelid) /
          nullif(pg_relation_size(indrelid), 0), 2) AS index_ratio
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC;

-- 예시:
-- indexrelname        | index_size | table_size | index_ratio
-- --------------------+------------+------------+------------
-- idx_orders_items    | 150 MB     | 500 MB     | 30.00
-- idx_products_name   | 80 MB      | 300 MB     | 26.67
```

## B-tree 인덱스

### 1. B-tree 구조

**Balanced Tree (균형 트리):**

```
                [Root Node]
                /    |    \
         [Internal][Internal][Internal]
          /  |  \    /  |  \    /  |  \
      [Leaf][Leaf][Leaf][Leaf][Leaf][Leaf]
        ↓     ↓     ↓     ↓     ↓     ↓
      CTID  CTID  CTID  CTID  CTID  CTID
```

**특징:**
- 모든 Leaf Node는 같은 깊이 (균형)
- 정렬된 순서로 저장
- 각 노드는 여러 키를 가짐 (페이지 크기까지)
- 범위 검색 효율적 (Leaf Node는 연결 리스트)

**실제 구조 확인 (pageinspect):**

```sql
CREATE EXTENSION pageinspect;

-- B-tree 메타 페이지
SELECT * FROM bt_metap('idx_users_email');
-- magic  | version | root | level | fastroot | fastlevel
-- -------+---------+------+-------+----------+----------
-- 340322 |       4 |    3 |     2 |        3 |         2

-- Root 페이지 확인
SELECT * FROM bt_page_items('idx_users_email', 3);
-- itemoffset | ctid  | itemlen | data
-- -----------+-------+---------+----------------------
--          1 | (1,1) |      16 | alice@example.com
--          2 | (2,5) |      16 | bob@example.com
```

### 2. B-tree 검색 과정

**예시: email = 'charlie@example.com' 검색**

```
1. Root Node 읽기
   keys: [alice, john, tom]
   'charlie' < 'john' → 왼쪽 자식

2. Internal Node 읽기
   keys: [alice, bob, david, frank]
   'bob' < 'charlie' < 'david' → 중간 자식

3. Leaf Node 읽기
   keys: [charlie, chris, claire]
   'charlie' 발견 → CTID (5, 10)

4. 테이블 페이지 5, 오프셋 10 읽기
   → 실제 행 반환
```

**I/O 횟수:**
- Level 2 트리: 3번 (Root + Internal + Leaf)
- Level 3 트리: 4번
- 테이블 읽기: 1번
- **총 4-5번 I/O** (캐시 히트 시 0-1번)

### 3. 페이지 분할 (Page Split)

**문제:**
- Leaf Node가 가득 참 (8KB 페이지)
- 새 키 삽입 불가

**해결: 페이지 분할**

```
Before (페이지 가득 참):
[alice, bob, charlie, david, emma, frank] (8KB)

Insert: 'george'

After (분할):
[alice, bob, charlie] (4KB)
[david, emma, frank, george] (4KB)
     ↑
Parent Node에 새 포인터 추가
```

**분할로 인한 문제:**
- 쓰기 성능 저하 (추가 I/O)
- 인덱스 Bloat (페이지 절반만 사용)
- 단편화 증가

**Fillfactor로 완화:**

```sql
-- 인덱스 생성 시 fillfactor 설정
CREATE INDEX idx_users_email ON users(email)
WITH (fillfactor = 70);
-- 페이지의 70%만 채움, 30%는 미래 삽입 위해 예약
-- 페이지 분할 빈도 감소

-- 기본값: 90 (B-tree), 100 (Hash)
```

### 4. 중복 처리 (Duplicate Keys)

PostgreSQL 13+는 중복 키를 효율적으로 처리합니다.

**이전 버전 (≤12):**
```
Leaf Node:
[alice, CTID1]
[alice, CTID2]
[alice, CTID3]
...
[alice, CTID100]
→ 100개 엔트리
```

**PostgreSQL 13+ (Deduplication):**
```
Leaf Node:
[alice, [CTID1, CTID2, ..., CTID100]]
→ 1개 엔트리 (압축)
```

**효과:**
- 인덱스 크기 감소 (최대 90%)
- 페이지 분할 감소
- 성능 향상

**확인:**

```sql
-- Deduplication 통계
SELECT
    indexrelname,
    idx_blks_read,
    idx_blks_hit
FROM pg_stat_user_indexes
WHERE indexrelname = 'idx_orders_status';
```

### 5. PostgreSQL 17: IN절 성능 개선

PostgreSQL 17은 `IN (...)` 절의 B-tree 검색을 최적화했습니다.

**이전 버전:**
```sql
SELECT * FROM users WHERE user_id IN (1, 5, 10, 15, 20);
-- 각 값마다 별도 B-tree 탐색 (5번)
```

**PostgreSQL 17:**
```sql
-- IN 절 값을 정렬 후 B-tree 순차 스캔
-- 1번의 트리 탐색 + 순차 읽기
-- 성능: 30-40% 향상 (값이 많을수록 더 큰 효과)
```

**벤치마크:**

```sql
-- 테스트: 1000개 값 IN 절
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE order_id IN (
    SELECT generate_series(1, 1000)
);

-- PostgreSQL 16: 350ms
-- PostgreSQL 17: 240ms (31% 향상)
```

## Hash 인덱스

### 1. Hash 구조

**해시 함수 사용:**

```
Key → Hash Function → Bucket Number → Bucket Page

예시:
'alice@example.com' → hash() → 12345 → Page 12345
'bob@example.com'   → hash() → 67890 → Page 67890
```

**특징:**
- O(1) 검색 (이론적)
- 등호 검색만 가능 (=)
- 범위 검색 불가 (<, >, BETWEEN)
- 정렬 불가 (ORDER BY에 도움 안 됨)

### 2. Hash 인덱스 사용 시기

```sql
-- 적합: 등호 검색만
CREATE INDEX idx_users_email_hash ON users USING hash(email);

SELECT * FROM users WHERE email = 'alice@example.com';
-- Hash Index Scan (빠름)

-- 부적합: 범위 검색
SELECT * FROM users WHERE email > 'a@example.com';
-- Seq Scan (Hash 인덱스 사용 안 됨)

-- 부적합: LIKE
SELECT * FROM users WHERE email LIKE 'alice%';
-- Seq Scan
```

### 3. Hash vs B-tree 성능 비교

**벤치마크 (100만 건 테이블):**

```sql
-- B-tree
CREATE INDEX idx_btree ON users USING btree(email);
EXPLAIN (ANALYZE) SELECT * FROM users WHERE email = 'user500000@example.com';
-- Planning time: 0.123 ms
-- Execution time: 0.045 ms
-- Index size: 42 MB

-- Hash
CREATE INDEX idx_hash ON users USING hash(email);
EXPLAIN (ANALYZE) SELECT * FROM users WHERE email = 'user500000@example.com';
-- Planning time: 0.098 ms
-- Execution time: 0.038 ms (약간 빠름)
-- Index size: 38 MB (작음)
```

**결론:**
- Hash가 약간 빠르지만 차이 미미
- B-tree가 범용성 높음
- 대부분의 경우 B-tree 권장

### 4. Hash 인덱스의 한계

PostgreSQL 10 이전:
- WAL 로깅 안 됨 (복제 불가)
- 크래시 복구 안 됨

PostgreSQL 10+:
- WAL 로깅 지원
- 프로덕션 사용 가능

하지만 여전히 제한적:
- 범위 검색 불가
- Unique 제약 불가
- Covering Index 불가

## GiST (Generalized Search Tree)

### 1. GiST란?

**범용 검색 트리:**
- 여러 데이터 타입 지원 (기하학, 범위, 전문검색 등)
- 확장 가능한 프레임워크
- 손실 압축 가능 (False Positive 허용)

**지원 데이터 타입:**
- 기하학: point, box, circle, polygon
- 범위: int4range, tsrange, daterange
- 네트워크: inet, cidr
- 전문검색: tsvector (GIN이 더 나음)

### 2. GiST 인덱스 예시

**기하학 데이터:**

```sql
-- 매장 위치 테이블
CREATE TABLE stores (
    store_id INT PRIMARY KEY,
    name VARCHAR(100),
    location POINT  -- (경도, 위도)
);

-- GiST 인덱스
CREATE INDEX idx_stores_location ON stores USING gist(location);

-- 반경 검색
SELECT name, location
FROM stores
WHERE location <-> point(127.0, 37.5) < 5  -- 5km 반경
ORDER BY location <-> point(127.0, 37.5)  -- 거리 순 정렬
LIMIT 10;
-- GiST Index Scan (매우 빠름)
```

**범위 타입:**

```sql
-- 프로모션 기간 테이블
CREATE TABLE promotions (
    promo_id INT PRIMARY KEY,
    name VARCHAR(100),
    valid_period TSTZRANGE  -- 시작-종료 시간 범위
);

-- GiST 인덱스
CREATE INDEX idx_promotions_period ON promotions USING gist(valid_period);

-- 현재 유효한 프로모션 찾기
SELECT name, valid_period
FROM promotions
WHERE valid_period @> NOW();  -- @>: 포함 연산자
-- GiST Index Scan
```

### 3. GiST vs B-tree

| 기능 | B-tree | GiST |
|------|--------|------|
| 등호 검색 | ✅ | ✅ |
| 범위 검색 | ✅ | ✅ |
| 기하학 검색 | ❌ | ✅ |
| 범위 타입 | ❌ | ✅ |
| 정확도 | 100% | ~99% (손실 압축) |
| 크기 | 작음 | 큼 |
| 성능 | 빠름 | 보통 |

## SP-GiST (Space-Partitioned GiST)

### 1. SP-GiST란?

**공간 분할 트리:**
- 비균형 트리 허용
- Quad-tree, K-D tree 등 구현
- 데이터 분포에 적응

**적합한 데이터:**
- 비균일 분포
- 계층 구조 (IP 주소, 전화번호)
- 텍스트 접두사

### 2. SP-GiST 예시

**IP 주소:**

```sql
-- IP 주소 테이블
CREATE TABLE ip_blocks (
    block_id INT PRIMARY KEY,
    ip_range CIDR
);

-- SP-GiST 인덱스 (GiST보다 효율적)
CREATE INDEX idx_ip_blocks_range ON ip_blocks USING spgist(ip_range);

-- IP 주소 포함 여부 검색
SELECT * FROM ip_blocks
WHERE ip_range >>= '192.168.1.100'::inet;
-- SP-GiST Index Scan
```

**텍스트 접두사:**

```sql
-- SP-GiST로 LIKE 'prefix%' 최적화
CREATE INDEX idx_products_name_spgist ON products USING spgist(name text_ops);

SELECT * FROM products WHERE name LIKE 'iPhone%';
-- SP-GiST Index Scan (B-tree보다 빠를 수 있음)
```

## GIN (Generalized Inverted Index)

### 1. GIN이란?

**역인덱스 (Inverted Index):**
- 값 → 행 매핑 (일반 인덱스의 반대)
- 배열, JSONB, 전문검색에 최적

**구조:**

```
일반 B-tree:
행 ID → 값
1 → ['apple', 'banana']
2 → ['banana', 'cherry']

GIN:
값 → 행 ID 리스트
'apple' → [1]
'banana' → [1, 2]
'cherry' → [2]
```

### 2. 배열 인덱스

```sql
-- 상품 태그 (배열)
CREATE TABLE products (
    product_id INT PRIMARY KEY,
    name VARCHAR(100),
    tags TEXT[]  -- ['electronics', 'phone', 'smartphone']
);

-- GIN 인덱스
CREATE INDEX idx_products_tags ON products USING gin(tags);

-- 배열 포함 검색
SELECT * FROM products
WHERE tags @> ARRAY['smartphone'];  -- @>: 포함 연산자
-- GIN Index Scan

-- 배열 겹침 검색
SELECT * FROM products
WHERE tags && ARRAY['phone', 'laptop'];  -- &&: 겹침 연산자
-- GIN Index Scan
```

### 3. JSONB 인덱스

```sql
-- 상품 메타데이터 (JSONB)
CREATE TABLE products (
    product_id INT PRIMARY KEY,
    name VARCHAR(100),
    metadata JSONB
    -- {"brand": "Apple", "color": "black", "storage": "256GB"}
);

-- GIN 인덱스 (전체 JSONB)
CREATE INDEX idx_products_metadata ON products USING gin(metadata);

-- JSONB 키 존재 확인
SELECT * FROM products WHERE metadata ? 'brand';
-- GIN Index Scan

-- JSONB 값 검색
SELECT * FROM products WHERE metadata @> '{"brand": "Apple"}';
-- GIN Index Scan

-- 경로 지정 인덱스 (PostgreSQL 14+)
CREATE INDEX idx_products_brand ON products USING gin((metadata -> 'brand'));
```

### 4. 전문검색 (Full-Text Search)

```sql
-- 리뷰 테이블
CREATE TABLE reviews (
    review_id BIGSERIAL PRIMARY KEY,
    product_id INT,
    content TEXT,
    search_vector TSVECTOR  -- 전문검색용 벡터
);

-- tsvector 생성 트리거
CREATE TRIGGER reviews_search_vector_update
BEFORE INSERT OR UPDATE ON reviews
FOR EACH ROW EXECUTE FUNCTION
tsvector_update_trigger(search_vector, 'pg_catalog.english', content);

-- GIN 인덱스
CREATE INDEX idx_reviews_search ON reviews USING gin(search_vector);

-- 전문검색
SELECT review_id, content
FROM reviews
WHERE search_vector @@ to_tsquery('english', 'excellent & quality');
-- GIN Index Scan

-- 랭킹
SELECT review_id, content,
       ts_rank(search_vector, to_tsquery('excellent & quality')) AS rank
FROM reviews
WHERE search_vector @@ to_tsquery('excellent & quality')
ORDER BY rank DESC;
```

### 5. GIN 튜닝

**gin_pending_list_limit:**

GIN은 삽입을 버퍼링하여 성능을 높입니다.

```sql
-- 기본값: 4MB
SHOW gin_pending_list_limit;

-- 대용량 INSERT: 버퍼 늘리기
SET gin_pending_list_limit = 16384;  -- 16MB

-- Pending 리스트 강제 플러시
VACUUM products;
```

**fastupdate:**

```sql
-- 빠른 업데이트 활성화 (기본값: on)
CREATE INDEX idx_products_tags ON products USING gin(tags)
WITH (fastupdate = on);

-- 비활성화: 실시간 인덱스 갱신 (느리지만 일관성)
ALTER INDEX idx_products_tags SET (fastupdate = off);
```

## BRIN (Block Range Index)

### 1. BRIN이란?

**블록 범위 인덱스:**
- 물리적으로 정렬된 대용량 테이블에 최적
- 블록 범위마다 min/max 값 저장
- 극도로 작은 인덱스 크기

**구조:**

```
테이블 블록:
[블록 0-127]: created_at min=2026-01-01, max=2026-01-05
[블록 128-255]: created_at min=2026-01-06, max=2026-01-10
[블록 256-383]: created_at min=2026-01-11, max=2026-01-15

인덱스 크기: 수십 KB (B-tree는 수십 MB)
```

### 2. BRIN 적합한 시나리오

**시계열 데이터:**

```sql
-- 이벤트 로그 (시간 순 삽입)
CREATE TABLE event_logs (
    event_id BIGSERIAL PRIMARY KEY,
    user_id INT,
    event_type VARCHAR(50),
    event_data JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

-- BRIN 인덱스
CREATE INDEX idx_event_logs_created ON event_logs USING brin(created_at)
WITH (pages_per_range = 128);  -- 128 페이지당 하나의 범위

-- 날짜 범위 검색
SELECT * FROM event_logs
WHERE created_at BETWEEN '2026-01-01' AND '2026-01-07';
-- BRIN Index Scan
-- 해당 날짜가 포함될 수 있는 블록만 스캔
```

### 3. BRIN vs B-tree

**100억 건 테이블 (시계열):**

```sql
-- B-tree
CREATE INDEX idx_btree ON event_logs(created_at);
-- 인덱스 크기: 215 GB
-- 검색 시간: 50ms

-- BRIN
CREATE INDEX idx_brin ON event_logs USING brin(created_at);
-- 인덱스 크기: 2 MB (1/100,000)
-- 검색 시간: 80ms (약간 느림)

-- 결론: 디스크 절약이 중요하고 약간의 성능 손실 허용 시 BRIN
```

### 4. PostgreSQL 17: 병렬 BRIN 생성

```sql
-- 대용량 테이블에 BRIN 인덱스 생성
CREATE INDEX idx_event_logs_created ON event_logs USING brin(created_at)
WITH (pages_per_range = 128);

-- PostgreSQL 17: 병렬 생성 지원
SET max_parallel_maintenance_workers = 4;
CREATE INDEX idx_event_logs_created ON event_logs USING brin(created_at);
-- 4배 빠름
```

### 5. BRIN 주의사항

**물리적 정렬 필수:**

```sql
-- 나쁜 예: 랜덤 삽입
INSERT INTO event_logs (created_at) VALUES
    ('2026-01-10'),
    ('2026-01-02'),
    ('2026-01-15'),
    ('2026-01-01');
-- 블록마다 min/max 범위가 넓어짐 → BRIN 비효율

-- 좋은 예: 시간 순 삽입
INSERT INTO event_logs (created_at) VALUES
    ('2026-01-01'),
    ('2026-01-02'),
    ('2026-01-10'),
    ('2026-01-15');
-- 블록마다 범위 좁음 → BRIN 효율
```

**정렬되지 않은 테이블 정리:**

```sql
-- CLUSTER로 물리적 정렬
CLUSTER event_logs USING event_logs_pkey;
-- PK 순서로 테이블 재작성

-- BRIN 인덱스 재구성
REINDEX INDEX idx_event_logs_created;
```

## 인덱스 설계 패턴

### 1. Partial Index (부분 인덱스)

**일부 행만 인덱싱:**

```sql
-- 주문 중 'pending' 상태만 (전체의 5%)
CREATE INDEX idx_orders_pending ON orders(user_id)
WHERE status = 'pending';

-- 효과
SELECT * FROM orders WHERE user_id = 100 AND status = 'pending';
-- 작은 인덱스 사용 (빠름)

-- 비교: 전체 인덱스
CREATE INDEX idx_orders_user_id ON orders(user_id);
-- 크기: 100 MB
-- Partial Index 크기: 5 MB (1/20)
```

**NULL 제외:**

```sql
-- 이메일이 있는 사용자만
CREATE INDEX idx_users_email_not_null ON users(email)
WHERE email IS NOT NULL;
```

**소프트 삭제:**

```sql
-- 삭제되지 않은 행만
CREATE INDEX idx_products_active ON products(product_id)
WHERE deleted_at IS NULL;
```

### 2. Expression Index (표현식 인덱스)

**함수 결과 인덱싱:**

```sql
-- 소문자 변환
CREATE INDEX idx_users_lower_email ON users(LOWER(email));

SELECT * FROM users WHERE LOWER(email) = 'alice@example.com';
-- Expression Index 사용

-- 날짜 추출
CREATE INDEX idx_orders_year ON orders(EXTRACT(YEAR FROM created_at));

SELECT * FROM orders WHERE EXTRACT(YEAR FROM created_at) = 2026;
-- Expression Index 사용
```

**JSONB 경로:**

```sql
-- JSONB 특정 키
CREATE INDEX idx_products_brand ON products((metadata->>'brand'));

SELECT * FROM products WHERE metadata->>'brand' = 'Apple';
-- Expression Index 사용
```

### 3. Covering Index (커버링 인덱스)

**INCLUDE 절로 추가 컬럼:**

```sql
-- 인덱스에 추가 컬럼 포함 (정렬은 안 됨)
CREATE INDEX idx_users_email_inc ON users(email)
INCLUDE (username, created_at);

-- Index Only Scan 가능
SELECT email, username, created_at
FROM users
WHERE email = 'alice@example.com';
-- 테이블 접근 없음 (매우 빠름)

-- 비교: INCLUDE 없이
-- Index Scan + Heap Fetch (느림)
```

**주의: INCLUDE 컬럼은 검색 조건에 사용 불가:**

```sql
-- 작동 안 함
SELECT * FROM users WHERE username = 'alice';
-- Seq Scan (INCLUDE 컬럼은 검색 키가 아님)
```

### 4. 멀티컬럼 인덱스 컬럼 순서

**순서가 중요한 이유:**

```sql
-- 인덱스: (A, B, C)
CREATE INDEX idx_abc ON table(A, B, C);

-- 사용 가능한 쿼리:
WHERE A = 1
WHERE A = 1 AND B = 2
WHERE A = 1 AND B = 2 AND C = 3

-- 사용 불가능한 쿼리:
WHERE B = 2  -- A 없이 B 사용 불가
WHERE C = 3  -- A, B 없이 C 사용 불가
WHERE B = 2 AND C = 3  -- A 없음
```

**최적 순서 결정:**

1. **선택도 높은 컬럼 먼저** (카디널리티 높음)
   ```sql
   -- email (고유): 선택도 높음
   -- status (3-4개 값): 선택도 낮음
   CREATE INDEX idx_users_email_status ON users(email, status);  -- 좋음
   CREATE INDEX idx_users_status_email ON users(status, email);  -- 나쁨
   ```

2. **자주 사용하는 컬럼 먼저**
   ```sql
   -- 90% 쿼리: WHERE user_id = ?
   -- 10% 쿼리: WHERE user_id = ? AND status = ?
   CREATE INDEX idx_orders_user_status ON orders(user_id, status);
   ```

3. **등호 조건 먼저, 범위 조건 나중**
   ```sql
   CREATE INDEX idx_orders_user_date ON orders(user_id, created_at);

   -- 좋은 쿼리
   WHERE user_id = 100 AND created_at > '2026-01-01';

   -- 나쁜 인덱스
   CREATE INDEX idx_orders_date_user ON orders(created_at, user_id);
   -- 범위 검색 후 등호 검색 비효율
   ```

### 5. 인덱스 통합 vs 분리

**하나의 복합 인덱스:**

```sql
CREATE INDEX idx_orders_user_status ON orders(user_id, status);

-- 커버하는 쿼리:
WHERE user_id = 100
WHERE user_id = 100 AND status = 'pending'
```

**두 개의 단일 인덱스:**

```sql
CREATE INDEX idx_orders_user ON orders(user_id);
CREATE INDEX idx_orders_status ON orders(status);

-- Bitmap Scan으로 조합 가능:
WHERE user_id = 100 AND status = 'pending';
-- Bitmap AND

-- 단점: 두 인덱스 유지 비용, 조합 오버헤드
```

**가이드라인:**
- 자주 함께 사용: 복합 인덱스
- 독립적 사용: 별도 인덱스
- 디스크/메모리 제약: 복합 인덱스 (적은 수)

## 실습 SQL

### 1. 인덱스 타입별 성능 비교

```sql
-- 테스트 테이블 (100만 건)
CREATE TABLE index_test (
    id SERIAL PRIMARY KEY,
    email VARCHAR(100),
    tags TEXT[],
    metadata JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO index_test (email, tags, metadata, created_at)
SELECT
    'user' || i || '@example.com',
    ARRAY['tag' || (i % 10), 'category' || (i % 5)],
    jsonb_build_object('user_id', i, 'score', random() * 100),
    NOW() - (random() * INTERVAL '365 days')
FROM generate_series(1, 1000000) AS i;

-- 1. B-tree 인덱스
CREATE INDEX idx_btree ON index_test USING btree(email);
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM index_test WHERE email = 'user500000@example.com';
-- Execution time: ~0.05ms

-- 2. Hash 인덱스
CREATE INDEX idx_hash ON index_test USING hash(email);
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM index_test WHERE email = 'user500000@example.com';
-- Execution time: ~0.04ms

-- 3. GIN 인덱스 (배열)
CREATE INDEX idx_gin ON index_test USING gin(tags);
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM index_test WHERE tags @> ARRAY['tag5'];
-- Execution time: ~2ms (10만 건 반환)

-- 4. BRIN 인덱스 (시계열)
CREATE INDEX idx_brin ON index_test USING brin(created_at);
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM index_test WHERE created_at > NOW() - INTERVAL '30 days';
-- Execution time: ~50ms (블록 스캔)

-- 인덱스 크기 비교
SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
FROM pg_indexes
WHERE tablename = 'index_test'
ORDER BY pg_relation_size(indexname::regclass) DESC;
```

### 2. 멀티컬럼 인덱스 실습

```sql
-- 주문 테이블
INSERT INTO orders (user_id, status, total_amount, created_at)
SELECT
    (random() * 10000)::int,
    (ARRAY['pending', 'processing', 'shipped', 'delivered'])[ceil(random()*4)],
    random() * 100000,
    NOW() - (random() * INTERVAL '365 days')
FROM generate_series(1, 1000000);

-- 잘못된 순서
CREATE INDEX idx_wrong ON orders(status, user_id);

EXPLAIN (ANALYZE)
SELECT * FROM orders WHERE user_id = 5000;
-- Seq Scan (인덱스 못 씀)

-- 올바른 순서
CREATE INDEX idx_correct ON orders(user_id, status);

EXPLAIN (ANALYZE)
SELECT * FROM orders WHERE user_id = 5000;
-- Index Scan (인덱스 사용)

EXPLAIN (ANALYZE)
SELECT * FROM orders WHERE user_id = 5000 AND status = 'pending';
-- Index Scan (더 효율적)
```

### 3. Covering Index vs 일반 Index

```sql
-- 일반 인덱스
CREATE INDEX idx_normal ON users(email);

EXPLAIN (ANALYZE, BUFFERS)
SELECT email, username FROM users WHERE email = 'user1000@example.com';
-- Index Scan + Heap Fetch
-- Buffers: shared hit=8

-- Covering Index
CREATE INDEX idx_covering ON users(email) INCLUDE (username);

EXPLAIN (ANALYZE, BUFFERS)
SELECT email, username FROM users WHERE email = 'user1000@example.com';
-- Index Only Scan
-- Buffers: shared hit=4 (50% 감소)
```

### 4. Partial Index 효과

```sql
-- 전체 인덱스
CREATE INDEX idx_full ON orders(user_id);
SELECT pg_size_pretty(pg_relation_size('idx_full'));
-- 21 MB

-- Partial Index (pending만, 5%)
CREATE INDEX idx_partial ON orders(user_id) WHERE status = 'pending';
SELECT pg_size_pretty(pg_relation_size('idx_partial'));
-- 1 MB (1/21)

EXPLAIN (ANALYZE)
SELECT * FROM orders WHERE user_id = 5000 AND status = 'pending';
-- Partial Index 사용 (빠름)
```

## 직접 확인해보기

### 1. 인덱스 사용 여부 확인

```sql
-- 인덱스 스캔 통계
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan,           -- 인덱스 스캔 횟수
    idx_tup_read,       -- 읽은 튜플 수
    idx_tup_fetch       -- 가져온 튜플 수
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC;

-- 사용 안 되는 인덱스 찾기
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
AND indexrelname NOT LIKE '%_pkey'  -- PK 제외
ORDER BY pg_relation_size(indexrelid) DESC;
-- 삭제 고려
```

### 2. 인덱스 Bloat 측정

```sql
-- pgstattuple 확장
CREATE EXTENSION pgstattuple;

SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size,
    (pgstatindex(indexrelid)).avg_leaf_density AS leaf_density,
    (pgstatindex(indexrelid)).leaf_fragmentation AS fragmentation
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC;

-- leaf_density < 50%: Bloat 심각
-- fragmentation > 50%: 단편화 심각
-- 해결: REINDEX
```

### 3. REINDEX 실습

```sql
-- 인덱스 재구성
REINDEX INDEX idx_users_email;

-- 테이블의 모든 인덱스
REINDEX TABLE users;

-- 동시성 (PostgreSQL 12+)
REINDEX INDEX CONCURRENTLY idx_users_email;
-- 서비스 중단 없음 (느림)

-- 시스템 전체
REINDEX DATABASE ecommerce;
-- 주의: 오래 걸림, 유지보수 시간에 실행
```

### 4. EXPLAIN으로 인덱스 선택 분석

```sql
-- 인덱스 선택 확인
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM orders
WHERE user_id = 100 AND status = 'pending';

-- 출력 분석:
-- -> Index Scan using idx_orders_user_status on orders
--    Index Cond: ((user_id = 100) AND (status = 'pending'))
--    Rows Removed by Index Recheck: 0
--    Buffers: shared hit=8

-- 강제로 Seq Scan (테스트용)
SET enable_indexscan = off;
EXPLAIN SELECT * FROM orders WHERE user_id = 100;
-- Seq Scan
SET enable_indexscan = on;
```

## 실무 팁

### 1. 인덱스 생성 타이밍

**프로덕션에서 안전한 인덱스 생성:**

```sql
-- 일반 CREATE INDEX: ACCESS EXCLUSIVE 락 (쓰기 차단)
CREATE INDEX idx_users_email ON users(email);
-- 수백만 건 테이블: 수십 분 소요, 서비스 중단

-- CONCURRENTLY: 락 최소화
CREATE INDEX CONCURRENTLY idx_users_email ON users(email);
-- 느리지만 서비스 중단 없음

-- 주의사항:
-- 1. 트랜잭션 안에서 사용 불가
-- 2. 실패 시 INVALID 인덱스 생성됨
-- 3. 정리: DROP INDEX CONCURRENTLY idx_users_email;
```

**INVALID 인덱스 확인:**

```sql
SELECT
    indexrelid::regclass AS index_name,
    indrelid::regclass AS table_name
FROM pg_index
WHERE NOT indisvalid;

-- INVALID 인덱스 삭제
DROP INDEX CONCURRENTLY idx_users_email;
```

### 2. 인덱스 모니터링 쿼리

```sql
-- 주간 리포트: 인덱스 효율성
WITH index_stats AS (
    SELECT
        schemaname,
        tablename,
        indexname,
        idx_scan,
        pg_relation_size(indexrelid) AS index_size,
        pg_relation_size(indrelid) AS table_size
    FROM pg_stat_user_indexes
    JOIN pg_index ON indexrelid = pg_index.indexrelid
)
SELECT
    indexname,
    tablename,
    idx_scan,
    pg_size_pretty(index_size) AS index_size,
    CASE
        WHEN idx_scan = 0 THEN '❌ 미사용 (삭제 고려)'
        WHEN idx_scan < 100 THEN '⚠️ 저사용'
        ELSE '✅ 정상'
    END AS status,
    ROUND(100.0 * index_size / NULLIF(table_size, 0), 2) AS index_ratio
FROM index_stats
WHERE schemaname = 'public'
ORDER BY idx_scan ASC, index_size DESC;
```

### 3. 인덱스 추천 (hypothetical index)

**pg_qualstats + HypoPG 확장:**

```sql
-- HypoPG: 가상 인덱스 생성 (실제 생성 안 함)
CREATE EXTENSION hypopg;

-- 가상 인덱스 추가
SELECT hypopg_create_index('CREATE INDEX ON orders(user_id, status)');

-- 쿼리가 가상 인덱스를 사용할지 확인
EXPLAIN SELECT * FROM orders WHERE user_id = 100 AND status = 'pending';
-- Index Scan using <hypopg index>

-- 가상 인덱스 삭제
SELECT hypopg_drop_index(<oid>);
SELECT hypopg_reset();  -- 모두 삭제
```

### 4. 인덱스 네이밍 컨벤션

```sql
-- 좋은 네이밍:
-- idx_<table>_<columns>_<type>
CREATE INDEX idx_users_email_btree ON users USING btree(email);
CREATE INDEX idx_products_tags_gin ON products USING gin(tags);
CREATE INDEX idx_orders_user_status ON orders(user_id, status);

-- Partial Index:
-- idx_<table>_<columns>_<condition>
CREATE INDEX idx_orders_user_pending ON orders(user_id) WHERE status = 'pending';

-- Expression Index:
-- idx_<table>_<expression>
CREATE INDEX idx_users_lower_email ON users(LOWER(email));
```

### 5. 인덱스 유지보수 체크리스트

```sql
-- 1. 미사용 인덱스 (월 1회)
SELECT indexrelname, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0 AND indexrelname NOT LIKE '%_pkey';

-- 2. Bloat 점검 (분기 1회)
SELECT indexrelname, (pgstatindex(indexrelid)).avg_leaf_density
FROM pg_stat_user_indexes
WHERE (pgstatindex(indexrelid)).avg_leaf_density < 50;

-- 3. 크기 모니터링 (월 1회)
SELECT
    indexrelname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;

-- 4. REINDEX 일정 (연 1회 또는 Bloat 발생 시)
REINDEX INDEX CONCURRENTLY idx_large_table;
```

### 6. 파티션 테이블 인덱스

```sql
-- 파티션 테이블
CREATE TABLE event_logs (
    event_id BIGSERIAL,
    user_id INT,
    created_at TIMESTAMP
) PARTITION BY RANGE (created_at);

-- 파티션
CREATE TABLE event_logs_2026_01 PARTITION OF event_logs
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');

-- 부모 테이블에 인덱스 생성 (자동으로 모든 파티션에 생성)
CREATE INDEX idx_event_logs_user ON event_logs(user_id);

-- 각 파티션에 자동 생성됨:
-- event_logs_2026_01_user_id_idx
-- event_logs_2026_02_user_id_idx
-- ...

-- 파티션별 인덱스 확인
SELECT
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass))
FROM pg_indexes
WHERE tablename LIKE 'event_logs_%'
ORDER BY tablename;
```

## 다이어그램 및 벤치마크 참조

이 노트와 함께 다음 자료를 참고하세요:
- `diagrams/06-btree-structure.drawio`: B-tree 내부 구조 및 검색 과정
- `benchmarks/06-index-comparison.md`: 인덱스 타입별 성능 벤치마크

## 참고 링크

### 공식 문서
- [Chapter 11. Indexes](https://www.postgresql.org/docs/17/indexes.html)
- [11.2. Index Types](https://www.postgresql.org/docs/17/indexes-types.html)
- [11.5. Combining Multiple Indexes](https://www.postgresql.org/docs/17/indexes-bitmap-scans.html)
- [11.8. Partial Indexes](https://www.postgresql.org/docs/17/indexes-partial.html)
- [11.9. Index-Only Scans](https://www.postgresql.org/docs/17/indexes-index-only-scans.html)
- [11.11. Indexes on Expressions](https://www.postgresql.org/docs/17/indexes-expressional.html)

### Internals
- [Chapter 64. B-Tree Indexes](https://www.postgresql.org/docs/17/btree.html)
- [Chapter 65. GiST Indexes](https://www.postgresql.org/docs/17/gist.html)
- [Chapter 66. SP-GiST Indexes](https://www.postgresql.org/docs/17/spgist.html)
- [Chapter 67. GIN Indexes](https://www.postgresql.org/docs/17/gin.html)
- [Chapter 68. BRIN Indexes](https://www.postgresql.org/docs/17/brin.html)

### 확장
- [pageinspect](https://www.postgresql.org/docs/17/pageinspect.html) - 인덱스 내부 확인
- [pgstattuple](https://www.postgresql.org/docs/17/pgstattuple.html) - Bloat 측정
- [HypoPG](https://hypopg.readthedocs.io/) - 가상 인덱스 테스트

### PostgreSQL 17 신기능
- [Release 17 - Indexes](https://www.postgresql.org/docs/17/release-17.html)
- B-tree IN절 최적화
- BRIN 병렬 빌드

### 심화 학습
- [The Internals of PostgreSQL: Indexes](http://www.interdb.jp/pg/pgsql08.html)
- [Understanding B-tree Indexes in PostgreSQL](https://www.cybertec-postgresql.com/en/b-tree-index-explained/)
- [GIN Indexes in PostgreSQL](https://www.percona.com/blog/2020/01/23/gin-indexes-in-postgresql/)
- [BRIN Indexes: Big Data Performance](https://www.2ndquadrant.com/en/blog/brin-indexes-big-data-performance/)

---

**다음 노트:** [07-query-optimization.md](./07-query-optimization.md)
**이전 노트:** [05-vacuum-and-maintenance.md](./05-vacuum-and-maintenance.md)
**목차로 돌아가기:** [README.md](../README.md)
