# 06. 인덱스 타입별 벤치마크

> 실습 후 EXPLAIN ANALYZE 결과를 기록하세요.

---

## 테스트 1: orders 테이블 날짜 범위 검색

### 조건
- 테이블 크기: ~50만 행
- 쿼리: `SELECT * FROM orders WHERE created_at BETWEEN '2024-01-01' AND '2024-01-31'`

### 결과 비교
| 항목 | 인덱스 없음 | B-tree | BRIN |
|------|------------|--------|------|
| 스캔 방식 | | | |
| 예상 cost | | | |
| 실제 시간(ms) | | | |
| Buffers shared hit | | | |
| Buffers shared read | | | |
| 행 반환 | | | |

### 분석
- (기록)

---

## 테스트 2: products 테이블 JSONB 검색

### 조건
- 테이블 크기: 5,000 행
- 쿼리: `SELECT * FROM products WHERE metadata @> '{"brand": "삼성"}'`

### 결과 비교
| 항목 | 인덱스 없음 | GIN |
|------|------------|-----|
| 스캔 방식 | | |
| 예상 cost | | |
| 실제 시간(ms) | | |
| Buffers shared hit | | |
| Buffers shared read | | |
| 행 반환 | | |

### 분석
- (기록)

---

## 테스트 3: 등호 검색 — B-tree vs Hash

### 조건
- 테이블 크기: ~50만 행
- 쿼리: `SELECT * FROM orders WHERE status = 'delivered'`

### 결과 비교
| 항목 | 인덱스 없음 | B-tree | Hash |
|------|------------|--------|------|
| 스캔 방식 | | | |
| 예상 cost | | | |
| 실제 시간(ms) | | | |
| Buffers shared hit | | | |
| Buffers shared read | | | |
| 행 반환 | | | |

### 분석
- (기록)

---

## 테스트 4: Partial Index 효과

### 조건
- 쿼리: `SELECT * FROM orders WHERE status = 'pending' AND created_at > '2025-01-01'`
- Partial Index: `CREATE INDEX ON orders(created_at) WHERE status = 'pending'`

### 결과 비교
| 항목 | Full Index | Partial Index |
|------|-----------|---------------|
| 인덱스 크기 | | |
| 스캔 방식 | | |
| 예상 cost | | |
| 실제 시간(ms) | | |

### 분석
- (기록)
