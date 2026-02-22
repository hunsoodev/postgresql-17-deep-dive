# pgvector 인덱스 튜닝 가이드

## 한줄 요약

pgvector는 PostgreSQL에서 벡터 유사도 검색을 가능하게 하는 확장으로, HNSW와 IVFFlat 두 가지 ANN 인덱스를 제공하며, `m`, `ef_construction`, `ef_search`, `lists`, `probes` 등의 파라미터와 PostgreSQL 메모리/병렬 설정을 적절히 조합해야 실무 수준의 recall과 latency를 달성할 수 있습니다.

> 📖 이 노트의 모든 내용은 [pgvector 공식 README](https://github.com/pgvector/pgvector)를 기반으로 작성되었습니다.
> pgvector는 PostgreSQL 13 이상을 지원하며, 이 문서는 PostgreSQL 17 환경을 기준으로 합니다.

## 실습 환경

```bash
cd docker && docker compose up -d
docker exec -it pg17-lab psql -U labuser -d ecommerce
```

> pgvector 확장을 사용하려면 Docker 이미지에 pgvector가 포함되어 있어야 합니다.
> 공식 이미지: `pgvector/pgvector:pg17`

```sql
-- 확장 설치
CREATE EXTENSION IF NOT EXISTS vector;

-- 설치 확인
SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';
```

---

## 목차

| # | 주제 | 핵심 상황 |
|---|------|----------|
| 1 | [벡터 타입과 거리 연산자](#1-벡터-타입과-거리-연산자) | 어떤 타입과 연산자를 써야 하는지 |
| 2 | [HNSW vs IVFFlat — 인덱스 선택](#2-hnsw-vs-ivfflat--인덱스-선택) | 두 인덱스의 특성과 선택 기준 |
| 3 | [HNSW 인덱스 튜닝](#3-hnsw-인덱스-튜닝) | m, ef_construction, ef_search 설정 |
| 4 | [IVFFlat 인덱스 튜닝](#4-ivfflat-인덱스-튜닝) | lists, probes 설정 |
| 5 | [인덱스 빌드 최적화](#5-인덱스-빌드-최적화) | maintenance_work_mem, 병렬 워커 |
| 6 | [필터링 전략](#6-필터링-전략) | WHERE 절과 벡터 검색 조합 |
| 7 | [스토리지 최적화](#7-스토리지-최적화) | halfvec, 양자화, PLAIN 스토리지 |
| 8 | [PG17 특이사항](#8-pg17-특이사항) | PostgreSQL 17에서의 주의점 |
| 9 | [실전 체크리스트](#9-실전-체크리스트) | 배포 전 확인 사항 |

---

## 1. 벡터 타입과 거리 연산자

### 벡터 타입

| 타입 | 차원 한도 | 요소당 크기 | 용도 |
|------|----------|-----------|------|
| `vector` | 2,000 | 4 bytes (float32) | 기본 벡터 타입 |
| `halfvec` | 4,000 | 2 bytes (float16) | 스토리지 절약, 대규모 데이터셋 |
| `bit` | 64,000 | 1 bit | 바이너리 양자화 |
| `sparsevec` | 비제로 16,000개 | 가변 | 희소 벡터 (NLP 등) |

> — [pgvector README: Vector Type](https://github.com/pgvector/pgvector#vector-type)

### 거리 연산자

| 연산자 | 의미 | 인덱스 ops 클래스 | 언제 쓰는가 |
|--------|------|------------------|------------|
| `<->` | L2 (유클리드) 거리 | `vector_l2_ops` | 임베딩 간 절대 거리가 중요할 때 |
| `<=>` | 코사인 거리 | `vector_cosine_ops` | 방향(의미 유사도)만 중요할 때 (가장 일반적) |
| `<#>` | 내적의 음수 | `vector_ip_ops` | 정규화된 벡터의 유사도 |
| `<+>` | L1 (맨해튼) 거리 | `vector_l1_ops` | 특수 케이스 |
| `<~>` | 해밍 거리 | `bit_hamming_ops` | 바이너리 벡터 비교 |
| `<%>` | 자카드 거리 | `bit_jaccard_ops` | 바이너리 벡터 집합 유사도 |

> — [pgvector README: Querying](https://github.com/pgvector/pgvector#querying)

**OpenAI, Cohere 등 대부분의 임베딩 모델은 정규화된 벡터를 반환하므로 `<=>` (코사인)이 가장 무난한 선택입니다.**

```sql
-- 테이블 생성 예시: 상품 임베딩 (1536차원, OpenAI text-embedding-3-small)
CREATE TABLE product_embeddings (
    product_id  bigint PRIMARY KEY REFERENCES products(id),
    embedding   vector(1536),
    created_at  timestamptz DEFAULT now()
);

-- 유사 상품 검색
SELECT p.name, pe.embedding <=> '[0.1,0.2,...]' AS distance
FROM product_embeddings pe
JOIN products p ON p.id = pe.product_id
ORDER BY pe.embedding <=> '[0.1,0.2,...]'
LIMIT 10;
```

---

## 2. HNSW vs IVFFlat — 인덱스 선택

### 비교 요약

| 특성 | HNSW | IVFFlat |
|------|------|---------|
| **알고리즘** | 계층적 탐색 가능한 소규모 세계 그래프 | k-means 클러스터링 + 역인덱스 |
| **빌드 시간** | 느림 (그래프 구축) | 상대적으로 빠름 |
| **빌드 메모리** | 높음 (그래프를 메모리에 유지) | 낮음 |
| **쿼리 성능** | 높은 recall + 낮은 latency | HNSW보다 약간 낮음 |
| **데이터 추가** | 즉시 그래프에 반영 | 기존 클러스터에 할당 (재빌드 필요할 수 있음) |
| **인덱스 크기** | 큼 | 상대적으로 작음 |

### 선택 기준

```
데이터 < 수만 건?
  → 인덱스 없이 exact search로 충분

데이터 수만~수백만 건?
  → HNSW (기본 권장)
  → 빌드 시간/메모리 제약이 크다면 IVFFlat

데이터가 자주 대량 갱신?
  → HNSW (IVFFlat은 클러스터 분포 변경 시 재빌드 필요)

recall이 매우 중요?
  → HNSW (동일 latency에서 recall이 더 높음)
```

> **pgvector 공식 권장:** HNSW를 기본으로 사용하되, 빌드 시간이 너무 길거나 메모리가 부족한 경우 IVFFlat을 고려하세요.
> — [pgvector README: HNSW](https://github.com/pgvector/pgvector#hnsw)

---

## 3. HNSW 인덱스 튜닝

### 파라미터 정리

| 파라미터 | 기본값 | 설정 시점 | 역할 |
|----------|--------|----------|------|
| `m` | 16 | 인덱스 생성 | 레이어당 최대 연결 수 |
| `ef_construction` | 64 | 인덱스 생성 | 빌드 시 후보 리스트 크기 |
| `ef_search` | 40 | 쿼리 시 (SET) | 검색 시 후보 리스트 크기 |

> — [pgvector README: HNSW - Index Options](https://github.com/pgvector/pgvector#hnsw)

### m (레이어당 최대 연결 수)

그래프의 각 노드가 가질 수 있는 최대 이웃 수입니다.

```
m 작음 (4~8)   → 인덱스 작고 빌드 빠름, recall 낮음
m 기본 (16)    → 대부분의 경우 적절
m 큼 (32~64)   → recall 높지만 인덱스 크기 증가, 빌드 느림
```

**비유:** 도시의 도로망. m이 크면 교차로마다 연결 도로가 많아 목적지를 더 빠르게 찾지만, 도로 건설비(인덱스 크기)가 증가합니다.

### ef_construction (빌드 시 후보 리스트)

인덱스를 빌드할 때 각 노드를 삽입하면서 탐색하는 후보 이웃의 수입니다.

```
ef_construction 작음 (32)    → 빌드 빠르지만 그래프 품질 낮음
ef_construction 기본 (64)    → 대부분 적절
ef_construction 큼 (128~256) → 그래프 품질 높지만 빌드 시간 증가
```

**핵심:** `ef_construction`은 인덱스 생성 후 변경할 수 없습니다. 나중에 recall이 부족하면 인덱스를 재빌드해야 합니다.

### ef_search (검색 시 후보 리스트)

쿼리 시 탐색할 후보 노드 수입니다. 런타임에 세션/트랜잭션 단위로 조절 가능합니다.

```sql
-- 기본값 확인
SHOW hnsw.ef_search;  -- 40

-- 세션 레벨 변경
SET hnsw.ef_search = 100;

-- 트랜잭션 레벨 변경 (단일 쿼리에만 적용)
BEGIN;
SET LOCAL hnsw.ef_search = 200;
SELECT * FROM product_embeddings
ORDER BY embedding <=> '[0.1,0.2,...]'
LIMIT 10;
COMMIT;
```

> — [pgvector README: HNSW - Query Options](https://github.com/pgvector/pgvector#hnsw)

### ef_search 튜닝 가이드

```
ef_search  |  recall  |  latency
-----------|----------|----------
    10     |   낮음   |   매우 빠름 (프로토타이핑)
    40     |   적당   |   빠름 (기본값)
   100     |   높음   |   보통 (프로덕션 권장 시작점)
   200     |  매우 높음 |  느림 (높은 정확도 필요 시)
   400+    |  ~1.0    |  매우 느림 (exact에 가까움)
```

**제약:** `ef_search`는 반드시 쿼리의 `LIMIT`보다 크거나 같아야 합니다.

### 인덱스 생성 예시

```sql
-- 기본 설정 (대부분 OK)
CREATE INDEX idx_product_emb_hnsw
ON product_embeddings USING hnsw (embedding vector_cosine_ops);

-- 높은 recall이 필요한 경우
CREATE INDEX idx_product_emb_hnsw_high
ON product_embeddings USING hnsw (embedding vector_cosine_ops)
WITH (m = 32, ef_construction = 128);

-- CONCURRENTLY: 프로덕션에서 테이블 락 방지
CREATE INDEX CONCURRENTLY idx_product_emb_hnsw
ON product_embeddings USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);
```

### Iterative Scan (필터링 시 결과 부족 해결)

벡터 인덱스 스캔 후 WHERE 필터가 적용되면 결과가 부족할 수 있습니다. Iterative scan은 자동으로 추가 튜플을 탐색합니다.

```sql
-- strict_order: 거리 순서 정확히 보장
SET hnsw.iterative_scan = strict_order;

-- relaxed_order: 순서가 약간 어긋나지만 recall 더 높음
SET hnsw.iterative_scan = relaxed_order;

-- 최대 스캔 튜플 수 (기본 ~20,000)
SET hnsw.max_scan_tuples = 50000;

-- work_mem 기반 메모리 배수 (기본 1)
SET hnsw.scan_mem_multiplier = 2;
```

> — [pgvector README: HNSW - Iterative Index Scans](https://github.com/pgvector/pgvector#hnsw)

---

## 4. IVFFlat 인덱스 튜닝

### 파라미터 정리

| 파라미터 | 기본값 | 설정 시점 | 역할 |
|----------|--------|----------|------|
| `lists` | — (필수) | 인덱스 생성 | k-means 클러스터(리스트) 수 |
| `probes` | 1 | 쿼리 시 (SET) | 검색할 리스트 수 |

> — [pgvector README: IVFFlat](https://github.com/pgvector/pgvector#ivfflat)

### lists 설정 가이드

```
행 수               | 권장 lists
--------------------|-------------------
~1만 이하           | 인덱스 불필요 (exact scan)
1만 ~ 100만         | rows / 1000
100만 이상          | sqrt(rows)
```

**예시:**
- 50만 행 → `lists = 500`
- 500만 행 → `lists = 2236` (≈ √5,000,000)

**주의:** IVFFlat은 인덱스 생성 시 데이터가 이미 존재해야 합니다. 빈 테이블에 먼저 인덱스를 만들면 클러스터링이 무의미합니다.

### probes 설정 가이드

```sql
-- 기본값: 1 (하나의 리스트만 검색 → 빠르지만 recall 낮음)
SHOW ivfflat.probes;

-- 권장 시작점: sqrt(lists)
SET ivfflat.probes = 22;  -- lists=500인 경우

-- 트랜잭션 레벨
BEGIN;
SET LOCAL ivfflat.probes = 50;
SELECT * FROM product_embeddings
ORDER BY embedding <=> '[0.1,0.2,...]'
LIMIT 10;
COMMIT;
```

```
probes / lists 비율  |  recall  |  latency
--------------------|----------|----------
   1 / 500          |   낮음   |  매우 빠름
  22 / 500 (√lists) |   적당   |  빠름 (권장 시작점)
  50 / 500          |   높음   |  보통
 100 / 500          |  매우 높음 |  느림
 500 / 500 (전부)   |   1.0    |  매우 느림 (≈ exact scan)
```

### IVFFlat Iterative Scan

```sql
-- 필터링된 쿼리에서 결과 부족 시
SET ivfflat.iterative_scan = relaxed_order;
SET ivfflat.max_probes = 100;  -- ivfflat.probes 이상이어야 동작

SELECT * FROM product_embeddings
WHERE created_at > '2025-01-01'
ORDER BY embedding <=> '[0.1,0.2,...]'
LIMIT 10;
```

> — [pgvector README: IVFFlat - Query Options](https://github.com/pgvector/pgvector#ivfflat)

### 인덱스 생성 예시

```sql
-- 데이터 로드 후 생성 (중요!)
CREATE INDEX idx_product_emb_ivf
ON product_embeddings USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 500);

-- 프로덕션 환경
CREATE INDEX CONCURRENTLY idx_product_emb_ivf
ON product_embeddings USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 500);
```

---

## 5. 인덱스 빌드 최적화

### maintenance_work_mem — 가장 중요한 설정

HNSW 인덱스 빌드 시 그래프가 `maintenance_work_mem`에 들어가지 않으면 성능이 급격히 저하됩니다. pgvector는 그래프가 메모리를 초과하면 NOTICE를 출력합니다.

```sql
-- 현재 값 확인
SHOW maintenance_work_mem;  -- 기본: 64MB (부족!)

-- 인덱스 빌드 직전에 세션 레벨로 올림
SET maintenance_work_mem = '2GB';   -- 중소 규모
SET maintenance_work_mem = '8GB';   -- 대규모 (수백만 벡터)

-- 인덱스 빌드
CREATE INDEX idx_product_emb_hnsw
ON product_embeddings USING hnsw (embedding vector_cosine_ops);

-- 빌드 후 원복 (다른 세션에 영향 없음)
RESET maintenance_work_mem;
```

> HNSW indexes are built faster when the whole graph fits into `maintenance_work_mem`.
> A notice is shown when the graph no longer fits.
> — [pgvector README: HNSW - Index Build Time](https://github.com/pgvector/pgvector#hnsw)

**메모리 추정 (대략):**
- 1M 벡터 × 1536차원 × float32 × m=16 기준 → ~10GB+ 그래프
- `maintenance_work_mem`을 이에 맞춰 설정하되, 서버 가용 메모리를 초과하지 않도록 주의

### 병렬 워커 활용

```sql
-- 병렬 인덱스 빌드 워커 수 (기본: 2, leader 포함 시 3)
SET max_parallel_maintenance_workers = 7;  -- leader + 7 = 8 병렬

-- max_parallel_workers가 충분한지 확인 (기본: 8)
SHOW max_parallel_workers;

-- 인덱스 빌드
CREATE INDEX idx_product_emb_hnsw
ON product_embeddings USING hnsw (embedding vector_cosine_ops);
```

> — [pgvector README: Index Build Time](https://github.com/pgvector/pgvector#index-build-time)

### 빌드 진행률 모니터링

```sql
-- 다른 세션에서 실행
SELECT phase,
       round(100.0 * blocks_done / nullif(blocks_total, 0), 1) AS "progress_%"
FROM pg_stat_progress_create_index;
```

HNSW 빌드 단계:
1. `initializing` → 2. `loading tuples` (진행률 표시)

IVFFlat 빌드 단계:
1. `initializing` → 2. `performing k-means` → 3. `assigning tuples` → 4. `loading tuples` (진행률 표시)

### 빌드 시간 최적화 요약

```
조치                           | 효과
-------------------------------|----------------------------------
maintenance_work_mem 올리기     | HNSW: 그래프 전체가 메모리에 → 수배 빨라짐
                               | IVFFlat: 효과 적음
max_parallel_maintenance_workers| 양쪽 모두 병렬 빌드 가능
데이터 로드 후 인덱스 생성      | 빈 인덱스에 한 건씩 추가하는 것보다 빠름
ef_construction / m 줄이기     | HNSW 빌드 빨라지지만 recall 감소
CONCURRENTLY 사용              | 빌드 중 쓰기 차단하지 않음 (시간은 더 걸림)
```

---

## 6. 필터링 전략

벡터 검색 + WHERE 절 조합은 실무에서 가장 까다로운 부분입니다.

### 문제: 필터 후 결과 부족

```sql
-- ef_search=40 기본값에서 인덱스가 40개 후보를 반환
-- category = 'electronics'가 전체의 10%라면 → ~4개만 매칭
SELECT * FROM product_embeddings pe
JOIN products p ON p.id = pe.product_id
WHERE p.category = 'electronics'
ORDER BY pe.embedding <=> '[0.1,0.2,...]'
LIMIT 10;  -- 10개를 원하지만 4개만 나올 수 있음
```

> — [pgvector README: Filtering](https://github.com/pgvector/pgvector#filtering)

### 해결 전략

#### 전략 1: ef_search / probes 올리기

```sql
-- 간단하지만 전체 쿼리가 느려짐
SET hnsw.ef_search = 200;
```

#### 전략 2: Iterative Scan 활성화 (권장)

```sql
-- 필터에 의해 결과가 부족하면 자동으로 추가 탐색
SET hnsw.iterative_scan = relaxed_order;

SELECT * FROM product_embeddings pe
JOIN products p ON p.id = pe.product_id
WHERE p.category = 'electronics'
ORDER BY pe.embedding <=> '[0.1,0.2,...]'
LIMIT 10;
```

#### 전략 3: Partial Index (필터 값이 소수일 때)

```sql
-- 특정 카테고리 전용 인덱스
CREATE INDEX idx_emb_electronics
ON product_embeddings USING hnsw (embedding vector_cosine_ops)
WHERE product_id IN (SELECT id FROM products WHERE category = 'electronics');
```

> — [pgvector README: Filtering - Partial Indexing](https://github.com/pgvector/pgvector#filtering)

#### 전략 4: 테이블 파티셔닝 (필터 값이 다수일 때)

```sql
-- 카테고리별 파티셔닝
CREATE TABLE product_embeddings (
    product_id  bigint,
    category    text,
    embedding   vector(1536)
) PARTITION BY LIST(category);

CREATE TABLE pe_electronics PARTITION OF product_embeddings
    FOR VALUES IN ('electronics');
CREATE TABLE pe_clothing PARTITION OF product_embeddings
    FOR VALUES IN ('clothing');
-- ...

-- 각 파티션에 인덱스 생성
CREATE INDEX ON pe_electronics USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON pe_clothing USING hnsw (embedding vector_cosine_ops);
```

> — [pgvector README: Filtering - Partitioning](https://github.com/pgvector/pgvector#filtering)

### 필터 전략 선택 흐름

```
필터 조건의 카디널리티?
  → 소수 (2~5개 값) → Partial Index
  → 다수 (10개+ 값) → 테이블 파티셔닝
  → 범위 조건 (날짜 등) → Iterative Scan
  → 복합 조건 → 필터 컬럼에 B-tree 인덱스 + Iterative Scan
```

---

## 7. 스토리지 최적화

### STORAGE PLAIN — TOAST 오버헤드 제거

PostgreSQL은 큰 값을 별도의 TOAST 테이블에 저장합니다. 벡터는 대부분 크기가 일정하고 항상 읽히므로, 인라인 저장이 유리합니다.

```sql
-- TOAST 대신 인라인 저장
ALTER TABLE product_embeddings
ALTER COLUMN embedding SET STORAGE PLAIN;
```

**효과:**
- 벡터 읽기 시 TOAST 테이블 접근 제거 → I/O 감소
- 병렬 스캔 시 비용 추정이 정확해져 병렬 계획 수립이 쉬워짐

> — [pgvector README: Performance - Exact Search](https://github.com/pgvector/pgvector#exact-search)

### halfvec — 스토리지 50% 절약

float32 (4 bytes) → float16 (2 bytes)으로 정밀도를 낮춰 스토리지를 절반으로 줄입니다.

```sql
-- 방법 1: 테이블 자체를 halfvec으로
CREATE TABLE product_embeddings_half (
    product_id  bigint PRIMARY KEY,
    embedding   halfvec(1536)
);

-- 방법 2: 기존 vector 컬럼에 halfvec 인덱스만 생성 (인덱스만 절약)
CREATE INDEX idx_emb_half
ON product_embeddings USING hnsw ((embedding::halfvec(1536)) halfvec_cosine_ops);

-- 쿼리 시 캐스팅 필수
SELECT * FROM product_embeddings
ORDER BY embedding::halfvec(1536) <=> '[0.1,0.2,...]'
LIMIT 10;
```

> — [pgvector README: Half-Precision Vectors](https://github.com/pgvector/pgvector#half-precision-vectors)

**halfvec이 적합한 경우:**
- 임베딩 모델이 충분히 좋아서 float16 정밀도 손실이 recall에 영향이 미미한 경우
- 대규모 데이터셋에서 인덱스 크기/빌드 시간을 줄이고 싶을 때

### Binary Quantization — 극단적 압축

벡터를 1-bit로 양자화하여 극적인 스토리지 절감과 속도 향상을 얻지만 정밀도가 크게 감소합니다.

```sql
-- 바이너리 양자화 인덱스
CREATE INDEX idx_emb_binary
ON product_embeddings USING hnsw ((binary_quantize(embedding)::bit(1536)) bit_hamming_ops);

-- 2단계 검색: 바이너리로 후보 추출 → 원본 벡터로 re-rank
WITH candidates AS (
    SELECT product_id, embedding
    FROM product_embeddings
    ORDER BY binary_quantize(embedding)::bit(1536) <~> binary_quantize('[0.1,0.2,...]'::vector(1536))::bit(1536)
    LIMIT 100  -- 넉넉히 후보 추출
)
SELECT product_id
FROM candidates
ORDER BY embedding <=> '[0.1,0.2,...]'
LIMIT 10;  -- 최종 결과
```

> — [pgvector README: Binary Quantization](https://github.com/pgvector/pgvector#binary-quantize)

---

## 8. PG17 특이사항

### Materialized CTE에서 거리 정렬

PostgreSQL 17에서 materialized CTE의 결과를 거리로 재정렬할 때, `+ 0`을 붙여야 올바르게 동작합니다.

```sql
-- PG17에서 relaxed_order 결과를 CTE로 감싼 뒤 정렬 시
SET hnsw.iterative_scan = relaxed_order;

WITH candidates AS MATERIALIZED (
    SELECT id, embedding <=> '[0.1,0.2,...]' AS distance
    FROM product_embeddings
    ORDER BY embedding <=> '[0.1,0.2,...]'
    LIMIT 20
)
SELECT * FROM candidates
ORDER BY distance + 0  -- ← PG17에서 필요
LIMIT 10;
```

> — [pgvector README: Query Options](https://github.com/pgvector/pgvector#query-options)

### 쿼리 병렬 처리

```sql
-- exact search (인덱스 없는 전체 스캔) 시 병렬 워커 활용
SET max_parallel_workers_per_gather = 4;

-- 병렬 스캔이 안 되면 비용 파라미터 조정
SET min_parallel_table_scan_size = 1;
SET parallel_setup_cost = 1;
```

---

## 9. 실전 체크리스트

### 인덱스 생성 전

- [ ] `CREATE EXTENSION vector;` 확인
- [ ] 벡터 차원 수가 모델 출력과 일치하는지 확인
- [ ] 데이터가 이미 로드되어 있는지 확인 (특히 IVFFlat)
- [ ] 거리 연산자와 ops 클래스가 일치하는지 확인 (코사인 → `vector_cosine_ops`)

### 인덱스 생성 시

```sql
-- HNSW 프로덕션 빌드 체크리스트
SET maintenance_work_mem = '4GB';          -- 서버 RAM의 25~50%
SET max_parallel_maintenance_workers = 7;   -- CPU 코어 수 - 1

CREATE INDEX CONCURRENTLY idx_emb_hnsw
ON product_embeddings USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

RESET maintenance_work_mem;
RESET max_parallel_maintenance_workers;
```

### 쿼리 튜닝 시

```sql
-- 1. recall 측정: exact search 결과와 비교
-- exact search (인덱스 무시)
SET enable_indexscan = off;
SELECT product_id FROM product_embeddings
ORDER BY embedding <=> $query LIMIT 10;

-- approximate search (인덱스 사용)
SET enable_indexscan = on;
SET hnsw.ef_search = 100;
SELECT product_id FROM product_embeddings
ORDER BY embedding <=> $query LIMIT 10;

-- 2. EXPLAIN으로 인덱스 사용 확인
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM product_embeddings
ORDER BY embedding <=> '[0.1,0.2,...]'
LIMIT 10;
-- "Index Scan using idx_emb_hnsw" 가 보여야 함
```

### VACUUM 관리

대량 UPDATE/DELETE 후에는 인덱스 효율이 떨어질 수 있습니다.

```sql
-- 벡터 테이블 VACUUM
VACUUM product_embeddings;

-- 심한 bloat 시 인덱스 재빌드 (CONCURRENTLY 권장)
REINDEX INDEX CONCURRENTLY idx_emb_hnsw;
```

> — [pgvector README: Vacuuming](https://github.com/pgvector/pgvector#vacuuming)

### 튜닝 파라미터 빠른 참조

```
┌───────────────────────────────────────────────────────────────────────┐
│                    pgvector 튜닝 파라미터 요약                        │
├───────────────────────────────────────────────────────────────────────┤
│ ❶ 인덱스 선택                                                       │
│   HNSW  — recall 우선, 실시간 INSERT OK                              │
│   IVFFlat — 빌드 빠르게, 메모리 절약                                  │
├───────────────────────────────────────────────────────────────────────┤
│ ❷ HNSW 빌드 파라미터                                                 │
│   m = 16 (기본)          연결 수. 올리면 recall↑ 크기↑                │
│   ef_construction = 64   빌드 정밀도. 올리면 recall↑ 빌드 시간↑       │
├───────────────────────────────────────────────────────────────────────┤
│ ❸ HNSW 쿼리 파라미터                                                 │
│   ef_search = 40 (기본)  올리면 recall↑ latency↑                     │
│   iterative_scan         필터링 시 자동 추가 탐색                     │
├───────────────────────────────────────────────────────────────────────┤
│ ❹ IVFFlat 빌드 파라미터                                              │
│   lists = rows/1000 또는 √rows                                      │
├───────────────────────────────────────────────────────────────────────┤
│ ❺ IVFFlat 쿼리 파라미터                                              │
│   probes = 1 (기본)      √lists가 시작점                             │
├───────────────────────────────────────────────────────────────────────┤
│ ❻ PG 서버 설정                                                       │
│   maintenance_work_mem   HNSW 빌드 시 핵심. 그래프 전체가 들어가야 함  │
│   max_parallel_maintenance_workers = 7   빌드 병렬화                  │
│   max_parallel_workers_per_gather = 4    exact search 병렬화          │
├───────────────────────────────────────────────────────────────────────┤
│ ❼ 스토리지                                                           │
│   STORAGE PLAIN          TOAST 오버헤드 제거                          │
│   halfvec 캐스팅 인덱스   인덱스 크기 50% 절약                        │
│   binary_quantize        극단적 압축 + re-rank 패턴                   │
└───────────────────────────────────────────────────────────────────────┘
```

---

## 참고 자료

- [pgvector 공식 GitHub](https://github.com/pgvector/pgvector) — 이 노트의 기본 출처
- [PostgreSQL 17 문서: CREATE INDEX](https://www.postgresql.org/docs/17/sql-createindex.html)
- [PostgreSQL 17 문서: GUC Parameters](https://www.postgresql.org/docs/17/runtime-config.html)
