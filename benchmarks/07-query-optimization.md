# 07. 쿼리 최적화 벤치마크

> 느린 쿼리를 분석하고 개선한 전후 수치를 기록하세요.

---

## 테스트 1: 사용자별 최근 주문 조회 (Top-N per group)

### 개선 전
```sql
-- 쿼리:
SELECT * FROM orders WHERE user_id = 12345 ORDER BY created_at DESC LIMIT 5;
```

| 항목 | 값 |
|------|----|
| 스캔 방식 | |
| 예상 cost | |
| 실제 시간(ms) | |
| Buffers shared hit | |
| Buffers shared read | |

### 개선 후 (인덱스 추가)
```sql
CREATE INDEX idx_orders_user_created ON orders(user_id, created_at DESC);
```

| 항목 | 값 |
|------|----|
| 스캔 방식 | |
| 예상 cost | |
| 실제 시간(ms) | |
| Buffers shared hit | |
| Buffers shared read | |

### 분석
- (기록)

---

## 테스트 2: 월별 매출 집계

### 쿼리
```sql
SELECT date_trunc('month', created_at) AS month,
       count(*) AS order_count,
       sum(total_amount) AS revenue
FROM orders
WHERE status IN ('paid','shipping','delivered')
GROUP BY 1
ORDER BY 1;
```

### 개선 전
| 항목 | 값 |
|------|----|
| 스캔 방식 | |
| 예상 cost | |
| 실제 시간(ms) | |

### 개선 후
| 항목 | 값 |
|------|----|
| 적용한 최적화 | |
| 스캔 방식 | |
| 예상 cost | |
| 실제 시간(ms) | |

### 분석
- (기록)

---

## 테스트 3: 병렬 쿼리 효과

### 조건
```sql
SET max_parallel_workers_per_gather = 0;  -- 병렬 OFF
SET max_parallel_workers_per_gather = 2;  -- 병렬 ON
```

### 결과 비교
| 항목 | 병렬 OFF | 병렬 ON (workers=2) |
|------|----------|-------------------|
| 스캔 방식 | | |
| 예상 cost | | |
| 실제 시간(ms) | | |
| Workers planned | 0 | |
| Workers launched | 0 | |

### 분석
- (기록)
