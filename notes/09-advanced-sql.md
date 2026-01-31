# 09. 고급 SQL

## 한줄 요약
Window Functions, Recursive CTE, LATERAL JOIN, JSON/JSONB, MERGE 등 PostgreSQL의 고급 SQL 기능을 실무 예제와 함께 다룬다.

## 왜 알아야 하는가

### 복잡한 비즈니스 로직 해결
- 애플리케이션 코드로 처리하던 복잡한 로직을 SQL로 효율적으로 해결
- 네트워크 왕복 감소 (한 번의 쿼리로 여러 작업)
- 데이터베이스 최적화 활용 (인덱스, 병렬 처리 등)

### 실무 시나리오
```
시나리오 1: 월별 매출 누적합과 이동평균
→ Window Functions 활용

시나리오 2: 카테고리 계층 구조 전체 조회
→ Recursive CTE 활용

시나리오 3: 각 카테고리별 상위 3개 상품
→ LATERAL JOIN 활용

시나리오 4: 비정형 상품 속성 저장/조회
→ JSONB 활용

시나리오 5: 재고 동기화 (INSERT/UPDATE/DELETE)
→ MERGE 활용
```

### PostgreSQL 17의 향상
- JSON_TABLE(), JSON_EXISTS() 등 SQL/JSON 표준 함수 추가
- COPY의 ON_ERROR 옵션으로 오류 무시 가능
- GROUP BY 최적화
- 병렬 처리 개선

## 핵심 개념

### 1. Window Functions 기초

#### Window Function이란?
- 집계 함수와 유사하지만 행을 그룹화하지 않음
- 각 행에 대해 "윈도우" (행의 집합)를 정의하고 계산
- ORDER BY, PARTITION BY로 윈도우 정의

#### 기본 구조
```sql
SELECT
  column1,
  column2,
  window_function() OVER (
    PARTITION BY partition_column
    ORDER BY order_column
    ROWS BETWEEN ... AND ...
  ) AS result
FROM table;
```

#### 주요 Window Functions

##### 1) 순위 함수
```sql
-- 샘플 데이터
CREATE TABLE sales (
  sale_id SERIAL PRIMARY KEY,
  product_name VARCHAR(100),
  category VARCHAR(50),
  amount DECIMAL(10,2),
  sale_date DATE
);

INSERT INTO sales (product_name, category, amount, sale_date) VALUES
('Laptop', 'Electronics', 1200.00, '2024-01-15'),
('Mouse', 'Electronics', 25.00, '2024-01-16'),
('Keyboard', 'Electronics', 75.00, '2024-01-17'),
('Desk', 'Furniture', 350.00, '2024-01-15'),
('Chair', 'Furniture', 200.00, '2024-01-16');

-- ROW_NUMBER(): 중복 없이 순차 번호
SELECT
  product_name,
  category,
  amount,
  ROW_NUMBER() OVER (PARTITION BY category ORDER BY amount DESC) AS row_num
FROM sales;
```

출력:
```
 product_name | category    | amount  | row_num
--------------+-------------+---------+---------
 Laptop       | Electronics | 1200.00 |       1
 Keyboard     | Electronics |   75.00 |       2
 Mouse        | Electronics |   25.00 |       3
 Desk         | Furniture   |  350.00 |       1
 Chair        | Furniture   |  200.00 |       2
```

```sql
-- RANK(): 동일 값에 같은 순위, 다음 순위 건너뜀
SELECT
  product_name,
  amount,
  RANK() OVER (ORDER BY amount DESC) AS rank
FROM sales;

-- DENSE_RANK(): 동일 값에 같은 순위, 다음 순위 연속
SELECT
  product_name,
  amount,
  DENSE_RANK() OVER (ORDER BY amount DESC) AS dense_rank
FROM sales;
```

##### 2) 집계 함수 (윈도우 모드)
```sql
-- 카테고리별 누적 합계
SELECT
  product_name,
  category,
  amount,
  SUM(amount) OVER (
    PARTITION BY category
    ORDER BY sale_date
  ) AS cumulative_sum
FROM sales;

-- 전체 대비 비율
SELECT
  product_name,
  category,
  amount,
  amount / SUM(amount) OVER () * 100 AS percentage_of_total
FROM sales;

-- 카테고리 내 평균과 비교
SELECT
  product_name,
  category,
  amount,
  AVG(amount) OVER (PARTITION BY category) AS category_avg,
  amount - AVG(amount) OVER (PARTITION BY category) AS diff_from_avg
FROM sales;
```

##### 3) 값 접근 함수
```sql
-- LAG(): 이전 행 값 가져오기
SELECT
  sale_date,
  amount,
  LAG(amount, 1) OVER (ORDER BY sale_date) AS prev_amount,
  amount - LAG(amount, 1) OVER (ORDER BY sale_date) AS diff
FROM sales;

-- LEAD(): 다음 행 값
SELECT
  sale_date,
  amount,
  LEAD(amount, 1) OVER (ORDER BY sale_date) AS next_amount
FROM sales;

-- FIRST_VALUE(), LAST_VALUE()
SELECT
  product_name,
  category,
  amount,
  FIRST_VALUE(product_name) OVER (
    PARTITION BY category
    ORDER BY amount DESC
  ) AS top_product_in_category
FROM sales;
```

### 2. Window Frame 절 (ROWS vs RANGE vs GROUPS)

#### ROWS: 물리적 행 기준
```sql
-- 현재 행 포함 이전 2행의 평균 (3일 이동평균)
SELECT
  sale_date,
  amount,
  AVG(amount) OVER (
    ORDER BY sale_date
    ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
  ) AS moving_avg_3
FROM sales;
```

Frame 지정자:
- `UNBOUNDED PRECEDING`: 파티션 시작
- `N PRECEDING`: 현재 행 이전 N행
- `CURRENT ROW`: 현재 행
- `N FOLLOWING`: 현재 행 이후 N행
- `UNBOUNDED FOLLOWING`: 파티션 끝

#### RANGE: 논리적 값 기준
```sql
-- 같은 날짜 범위의 합계
SELECT
  sale_date,
  amount,
  SUM(amount) OVER (
    ORDER BY sale_date
    RANGE BETWEEN CURRENT ROW AND CURRENT ROW
  ) AS same_day_total
FROM sales;

-- NUMERIC 컬럼으로 범위 지정
SELECT
  amount,
  AVG(amount) OVER (
    ORDER BY amount
    RANGE BETWEEN 100 PRECEDING AND 100 FOLLOWING
  ) AS avg_within_100
FROM sales;
```

#### GROUPS: 동일 값 그룹 기준 (PostgreSQL 11+)
```sql
-- 같은 금액을 가진 그룹별 처리
SELECT
  amount,
  COUNT(*) OVER (
    ORDER BY amount
    GROUPS BETWEEN CURRENT ROW AND CURRENT ROW
  ) AS count_same_amount
FROM sales;
```

#### 이커머스 실습: 월별 매출 분석
```sql
-- 월별 매출과 누적합, 이동평균
WITH monthly_sales AS (
  SELECT
    DATE_TRUNC('month', created_at) AS month,
    SUM(total_amount) AS monthly_total
  FROM orders
  WHERE status = 'completed'
    AND created_at >= '2023-01-01'
  GROUP BY DATE_TRUNC('month', created_at)
)
SELECT
  month,
  monthly_total,
  -- 누적 합계
  SUM(monthly_total) OVER (ORDER BY month) AS cumulative_total,
  -- 전월 대비 증감
  monthly_total - LAG(monthly_total) OVER (ORDER BY month) AS mom_diff,
  -- 전월 대비 증감률
  ROUND(
    (monthly_total - LAG(monthly_total) OVER (ORDER BY month)) /
    NULLIF(LAG(monthly_total) OVER (ORDER BY month), 0) * 100,
    2
  ) AS mom_growth_pct,
  -- 3개월 이동평균
  AVG(monthly_total) OVER (
    ORDER BY month
    ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
  ) AS moving_avg_3m,
  -- 전체 대비 비율
  ROUND(
    monthly_total / SUM(monthly_total) OVER () * 100,
    2
  ) AS pct_of_total
FROM monthly_sales
ORDER BY month;
```

출력 예시:
```
   month   | monthly_total | cumulative_total | mom_diff | mom_growth_pct | moving_avg_3m | pct_of_total
-----------+---------------+------------------+----------+----------------+---------------+--------------
2023-01-01 |      45000.00 |         45000.00 |     NULL |           NULL |      45000.00 |         8.50
2023-02-01 |      52000.00 |         97000.00 |  7000.00 |          15.56 |      48500.00 |         9.81
2023-03-01 |      48000.00 |        145000.00 | -4000.00 |          -7.69 |      48333.33 |         9.06
2023-04-01 |      55000.00 |        200000.00 |  7000.00 |          14.58 |      51666.67 |        10.38
...
```

### 3. Top-N per Group 패턴

#### ROW_NUMBER로 구현
```sql
-- 각 카테고리별 상위 3개 상품 (매출 기준)
WITH product_sales AS (
  SELECT
    p.product_id,
    p.name AS product_name,
    c.name AS category_name,
    SUM(oi.quantity * oi.price) AS total_revenue,
    ROW_NUMBER() OVER (
      PARTITION BY c.category_id
      ORDER BY SUM(oi.quantity * oi.price) DESC
    ) AS rank_in_category
  FROM products p
  JOIN categories c ON p.category_id = c.category_id
  JOIN product_variants pv ON p.product_id = pv.product_id
  JOIN order_items oi ON pv.variant_id = oi.variant_id
  JOIN orders o ON oi.order_id = o.order_id
  WHERE o.status = 'completed'
  GROUP BY p.product_id, p.name, c.category_id, c.name
)
SELECT
  category_name,
  product_name,
  total_revenue,
  rank_in_category
FROM product_sales
WHERE rank_in_category <= 3
ORDER BY category_name, rank_in_category;
```

#### DISTINCT ON으로 Top-1
```sql
-- 각 카테고리별 최고 매출 상품 (1개만)
SELECT DISTINCT ON (c.name)
  c.name AS category_name,
  p.name AS product_name,
  SUM(oi.quantity * oi.price) AS total_revenue
FROM products p
JOIN categories c ON p.category_id = c.category_id
JOIN product_variants pv ON p.product_id = pv.product_id
JOIN order_items oi ON pv.variant_id = oi.variant_id
JOIN orders o ON oi.order_id = o.order_id
WHERE o.status = 'completed'
GROUP BY c.name, p.name
ORDER BY c.name, SUM(oi.quantity * oi.price) DESC;
```

### 4. CTE (Common Table Expressions)

#### 기본 CTE
```sql
-- WITH 절로 임시 결과 정의
WITH high_value_customers AS (
  SELECT
    user_id,
    SUM(total_amount) AS lifetime_value
  FROM orders
  WHERE status = 'completed'
  GROUP BY user_id
  HAVING SUM(total_amount) > 10000
)
SELECT
  u.username,
  u.email,
  hvc.lifetime_value
FROM high_value_customers hvc
JOIN users u ON hvc.user_id = u.user_id
ORDER BY hvc.lifetime_value DESC;
```

#### 여러 CTE 연결
```sql
WITH
-- CTE 1: 월별 매출
monthly_revenue AS (
  SELECT
    DATE_TRUNC('month', created_at) AS month,
    SUM(total_amount) AS revenue
  FROM orders
  WHERE status = 'completed'
  GROUP BY DATE_TRUNC('month', created_at)
),
-- CTE 2: 월별 신규 고객 수
monthly_new_customers AS (
  SELECT
    DATE_TRUNC('month', created_at) AS month,
    COUNT(DISTINCT user_id) AS new_customers
  FROM users
  GROUP BY DATE_TRUNC('month', created_at)
)
-- 최종 조회: 두 CTE 조인
SELECT
  mr.month,
  mr.revenue,
  mnc.new_customers,
  mr.revenue / NULLIF(mnc.new_customers, 0) AS revenue_per_new_customer
FROM monthly_revenue mr
JOIN monthly_new_customers mnc ON mr.month = mnc.month
ORDER BY mr.month;
```

#### MATERIALIZED vs NOT MATERIALIZED (PostgreSQL 12+)
```sql
-- MATERIALIZED: 한 번 실행하고 결과 재사용
WITH expensive_calculation AS MATERIALIZED (
  SELECT
    user_id,
    SUM(total_amount) AS total_spent,
    COUNT(*) AS order_count
  FROM orders
  GROUP BY user_id
)
SELECT * FROM expensive_calculation WHERE total_spent > 1000
UNION ALL
SELECT * FROM expensive_calculation WHERE order_count > 10;
-- expensive_calculation은 한 번만 실행

-- NOT MATERIALIZED: 참조할 때마다 실행 (인라인)
WITH simple_filter AS NOT MATERIALIZED (
  SELECT * FROM orders WHERE status = 'completed'
)
SELECT * FROM simple_filter WHERE user_id = 123;
-- PostgreSQL 17: 자동으로 최적화 (명시 불필요)
```

### 5. Recursive CTE

#### 재귀 CTE 구조
```sql
WITH RECURSIVE cte_name AS (
  -- Anchor Member (기저 케이스)
  SELECT ... FROM ... WHERE ...

  UNION ALL

  -- Recursive Member (재귀 케이스)
  SELECT ... FROM ... JOIN cte_name ON ...
)
SELECT * FROM cte_name;
```

#### 카테고리 계층 구조 탐색
```sql
-- 샘플 데이터
INSERT INTO categories (category_id, name, parent_category_id, level) VALUES
(1, 'Electronics', NULL, 0),
(2, 'Computers', 1, 1),
(3, 'Laptops', 2, 2),
(4, 'Gaming Laptops', 3, 3),
(5, 'Business Laptops', 3, 3),
(6, 'Desktops', 2, 2),
(7, 'Mobile Phones', 1, 1),
(8, 'Smartphones', 7, 2);

-- 특정 카테고리의 모든 하위 카테고리 찾기
WITH RECURSIVE subcategories AS (
  -- Anchor: 시작 카테고리 (Computers)
  SELECT category_id, name, parent_category_id, level, name AS path
  FROM categories
  WHERE category_id = 2

  UNION ALL

  -- Recursive: 자식 카테고리들
  SELECT c.category_id, c.name, c.parent_category_id, c.level,
         sc.path || ' > ' || c.name AS path
  FROM categories c
  JOIN subcategories sc ON c.parent_category_id = sc.category_id
)
SELECT category_id, name, level, path
FROM subcategories
ORDER BY path;
```

출력:
```
 category_id |      name       | level |                  path
-------------+-----------------+-------+----------------------------------------
           2 | Computers       |     1 | Computers
           3 | Laptops         |     2 | Computers > Laptops
           4 | Gaming Laptops  |     3 | Computers > Laptops > Gaming Laptops
           5 | Business Laptops|     3 | Computers > Laptops > Business Laptops
           6 | Desktops        |     2 | Computers > Desktops
```

#### 상위 카테고리 경로 찾기
```sql
-- 특정 카테고리에서 최상위까지 경로
WITH RECURSIVE parent_chain AS (
  -- Anchor: 시작 카테고리 (Gaming Laptops)
  SELECT category_id, name, parent_category_id, level, 1 AS depth
  FROM categories
  WHERE category_id = 4

  UNION ALL

  -- Recursive: 부모 카테고리
  SELECT c.category_id, c.name, c.parent_category_id, c.level, pc.depth + 1
  FROM categories c
  JOIN parent_chain pc ON c.category_id = pc.parent_category_id
)
SELECT category_id, name, level, depth
FROM parent_chain
ORDER BY depth DESC;
```

출력:
```
 category_id |      name      | level | depth
-------------+----------------+-------+-------
           1 | Electronics    |     0 |     4
           2 | Computers      |     1 |     3
           3 | Laptops        |     2 |     2
           4 | Gaming Laptops |     3 |     1
```

#### 재귀 깊이 제한
```sql
-- 무한 루프 방지: 최대 깊이 설정
WITH RECURSIVE subcategories AS (
  SELECT category_id, name, parent_category_id, level, 0 AS depth
  FROM categories
  WHERE category_id = 1

  UNION ALL

  SELECT c.category_id, c.name, c.parent_category_id, c.level, sc.depth + 1
  FROM categories c
  JOIN subcategories sc ON c.parent_category_id = sc.category_id
  WHERE sc.depth < 10  -- 최대 10단계
)
SELECT * FROM subcategories;
```

#### 실무 예제: 조직 구조
```sql
CREATE TABLE employees (
  employee_id SERIAL PRIMARY KEY,
  name VARCHAR(100),
  manager_id INT REFERENCES employees(employee_id),
  title VARCHAR(100)
);

-- 특정 매니저 아래 모든 직원
WITH RECURSIVE org_chart AS (
  -- Anchor: 특정 매니저
  SELECT employee_id, name, manager_id, title, 0 AS level
  FROM employees
  WHERE employee_id = 1  -- CEO

  UNION ALL

  -- Recursive: 부하 직원들
  SELECT e.employee_id, e.name, e.manager_id, e.title, oc.level + 1
  FROM employees e
  JOIN org_chart oc ON e.manager_id = oc.employee_id
)
SELECT
  REPEAT('  ', level) || name AS org_structure,
  title,
  level
FROM org_chart
ORDER BY level, name;
```

### 6. LATERAL JOIN

#### LATERAL이란?
- 서브쿼리가 외부 쿼리의 컬럼을 참조 가능
- FOR EACH ROW 처럼 동작
- Top-N per group 패턴에 유용

#### 기본 예제
```sql
-- 각 사용자의 최근 3개 주문
SELECT
  u.user_id,
  u.username,
  recent_orders.order_id,
  recent_orders.created_at,
  recent_orders.total_amount
FROM users u
CROSS JOIN LATERAL (
  SELECT order_id, created_at, total_amount
  FROM orders o
  WHERE o.user_id = u.user_id
  ORDER BY created_at DESC
  LIMIT 3
) AS recent_orders;
```

#### Window Function과 비교
```sql
-- Window Function 방식
WITH ranked_orders AS (
  SELECT
    o.*,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) AS rn
  FROM orders o
)
SELECT user_id, order_id, created_at, total_amount
FROM ranked_orders
WHERE rn <= 3;

-- LATERAL 방식 (더 효율적일 수 있음)
SELECT
  u.user_id,
  recent.order_id,
  recent.created_at,
  recent.total_amount
FROM users u
CROSS JOIN LATERAL (
  SELECT order_id, created_at, total_amount
  FROM orders
  WHERE user_id = u.user_id
  ORDER BY created_at DESC
  LIMIT 3
) AS recent;
```

#### 복잡한 예제: 카테고리별 Top-3 + 리뷰 정보
```sql
-- 각 카테고리의 상위 3개 상품과 최근 리뷰
SELECT
  c.name AS category_name,
  top_products.product_name,
  top_products.total_revenue,
  top_products.rank,
  latest_review.rating,
  latest_review.content
FROM categories c
CROSS JOIN LATERAL (
  -- 카테고리별 상위 3개 상품
  SELECT
    p.product_id,
    p.name AS product_name,
    SUM(oi.quantity * oi.price) AS total_revenue,
    ROW_NUMBER() OVER (ORDER BY SUM(oi.quantity * oi.price) DESC) AS rank
  FROM products p
  JOIN product_variants pv ON p.product_id = pv.product_id
  JOIN order_items oi ON pv.variant_id = oi.variant_id
  WHERE p.category_id = c.category_id
  GROUP BY p.product_id, p.name
  ORDER BY total_revenue DESC
  LIMIT 3
) AS top_products
LEFT JOIN LATERAL (
  -- 각 상품의 최근 리뷰
  SELECT rating, content, created_at
  FROM reviews
  WHERE product_id = top_products.product_id
  ORDER BY created_at DESC
  LIMIT 1
) AS latest_review ON TRUE;
```

### 7. GROUPING SETS, CUBE, ROLLUP

#### GROUPING SETS: 여러 그룹화 한 번에
```sql
-- 일반 GROUP BY: 3번 쿼리 필요
SELECT category, NULL AS status, SUM(total_amount)
FROM orders o JOIN products p ON ...
GROUP BY category
UNION ALL
SELECT NULL, status, SUM(total_amount)
FROM orders
GROUP BY status
UNION ALL
SELECT category, status, SUM(total_amount)
FROM orders o JOIN products p ON ...
GROUP BY category, status;

-- GROUPING SETS: 1번 쿼리
SELECT
  category,
  status,
  SUM(total_amount) AS total
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
JOIN product_variants pv ON oi.variant_id = pv.variant_id
JOIN products p ON pv.product_id = p.product_id
GROUP BY GROUPING SETS (
  (category),           -- 카테고리별
  (status),             -- 상태별
  (category, status),   -- 카테고리+상태별
  ()                    -- 전체 합계
);
```

#### ROLLUP: 계층적 합계
```sql
-- 연도 > 분기 > 월 계층 합계
SELECT
  EXTRACT(YEAR FROM created_at) AS year,
  EXTRACT(QUARTER FROM created_at) AS quarter,
  EXTRACT(MONTH FROM created_at) AS month,
  SUM(total_amount) AS total
FROM orders
GROUP BY ROLLUP (
  EXTRACT(YEAR FROM created_at),
  EXTRACT(QUARTER FROM created_at),
  EXTRACT(MONTH FROM created_at)
)
ORDER BY year, quarter, month;
```

출력 예시:
```
 year | quarter | month |  total
------+---------+-------+---------
 2024 |       1 |     1 |  45000   -- 2024-Q1-Jan
 2024 |       1 |     2 |  52000   -- 2024-Q1-Feb
 2024 |       1 |     3 |  48000   -- 2024-Q1-Mar
 2024 |       1 |  NULL | 145000   -- 2024-Q1 합계
 2024 |       2 |     4 |  55000   -- 2024-Q2-Apr
 2024 |       2 |  NULL |  55000   -- 2024-Q2 합계
 2024 |    NULL |  NULL | 200000   -- 2024년 합계
 NULL |    NULL |  NULL | 200000   -- 전체 합계
```

#### CUBE: 모든 조합
```sql
-- 모든 차원 조합의 합계
SELECT
  category,
  status,
  payment_method,
  SUM(total_amount) AS total
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
JOIN product_variants pv ON oi.variant_id = pv.variant_id
JOIN products p ON pv.product_id = p.product_id
GROUP BY CUBE (category, status, payment_method);

-- 생성되는 조합:
-- (category, status, payment_method)
-- (category, status)
-- (category, payment_method)
-- (status, payment_method)
-- (category)
-- (status)
-- (payment_method)
-- () - 전체
```

#### GROUPING() 함수: NULL 구분
```sql
SELECT
  category,
  status,
  SUM(total_amount) AS total,
  GROUPING(category) AS is_category_total,
  GROUPING(status) AS is_status_total,
  CASE
    WHEN GROUPING(category) = 1 AND GROUPING(status) = 1 THEN 'Grand Total'
    WHEN GROUPING(category) = 1 THEN 'Status Subtotal'
    WHEN GROUPING(status) = 1 THEN 'Category Subtotal'
    ELSE 'Detail'
  END AS level
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
JOIN product_variants pv ON oi.variant_id = pv.variant_id
JOIN products p ON pv.product_id = p.product_id
GROUP BY ROLLUP (category, status);
```

### 8. JSON/JSONB 심화

#### PostgreSQL 17: SQL/JSON 표준 함수

##### JSON_TABLE(): JSON을 테이블로 변환
```sql
-- 리뷰 메타데이터 예시
CREATE TABLE reviews (
  review_id SERIAL PRIMARY KEY,
  product_id INT,
  user_id INT,
  rating INT,
  metadata JSONB  -- {"tags": ["great", "fast"], "helpful_count": 42, "verified": true}
);

-- 샘플 데이터
INSERT INTO reviews (product_id, user_id, rating, metadata) VALUES
(101, 1, 5, '{"tags": ["great", "fast shipping"], "helpful_count": 42, "verified": true}'),
(101, 2, 4, '{"tags": ["good quality"], "helpful_count": 15, "verified": false}'),
(102, 3, 3, '{"tags": ["okay"], "helpful_count": 5, "verified": true}');

-- JSON_TABLE로 추출 (PostgreSQL 17)
SELECT
  r.review_id,
  r.rating,
  jt.*
FROM reviews r,
JSON_TABLE(
  r.metadata,
  '$' COLUMNS (
    helpful_count INT PATH '$.helpful_count',
    verified BOOLEAN PATH '$.verified',
    tags JSONB PATH '$.tags'
  )
) AS jt
WHERE jt.verified = true;
```

출력:
```
 review_id | rating | helpful_count | verified |         tags
-----------+--------+---------------+----------+----------------------
         1 |      5 |            42 | t        | ["great", "fast shipping"]
         3 |      3 |             5 | t        | ["okay"]
```

##### JSON_EXISTS(): 조건 확인
```sql
-- 특정 경로가 존재하는지 확인 (PostgreSQL 17)
SELECT review_id, metadata
FROM reviews
WHERE JSON_EXISTS(metadata, '$.tags ? (@ == "great")');

-- 기존 방식 (하위 호환)
SELECT review_id, metadata
FROM reviews
WHERE metadata @> '{"tags": ["great"]}';
```

##### JSON_VALUE(): 스칼라 값 추출
```sql
-- JSON에서 단일 값 추출 (PostgreSQL 17)
SELECT
  review_id,
  JSON_VALUE(metadata, '$.helpful_count' RETURNING INT) AS helpful_count,
  JSON_VALUE(metadata, '$.verified' RETURNING BOOLEAN) AS verified
FROM reviews;

-- 기존 방식
SELECT
  review_id,
  (metadata->>'helpful_count')::INT AS helpful_count,
  (metadata->>'verified')::BOOLEAN AS verified
FROM reviews;
```

##### JSON_QUERY(): JSON 객체/배열 추출
```sql
-- JSON 객체나 배열 추출 (PostgreSQL 17)
SELECT
  review_id,
  JSON_QUERY(metadata, '$.tags') AS tags
FROM reviews;

-- 기존 방식
SELECT
  review_id,
  metadata->'tags' AS tags
FROM reviews;
```

#### JSONB 연산자
```sql
-- 포함 여부: @>
SELECT * FROM reviews
WHERE metadata @> '{"verified": true}';

-- 키 존재: ?
SELECT * FROM reviews
WHERE metadata ? 'helpful_count';

-- 배열 요소 포함: @>
SELECT * FROM reviews
WHERE metadata->'tags' @> '["great"]';

-- 경로 접근: ->, ->>
SELECT
  review_id,
  metadata->'helpful_count' AS helpful_count,     -- JSONB
  metadata->>'helpful_count' AS helpful_count_text -- TEXT
FROM reviews;

-- 경로 접근: #>, #>>
SELECT
  review_id,
  metadata #> '{tags, 0}' AS first_tag,      -- JSONB
  metadata #>> '{tags, 0}' AS first_tag_text -- TEXT
FROM reviews;
```

#### JSONB 인덱스
```sql
-- GIN 인덱스: 포함 검색
CREATE INDEX idx_reviews_metadata ON reviews USING GIN (metadata);

-- 특정 경로만 인덱싱
CREATE INDEX idx_reviews_verified ON reviews ((metadata->>'verified'));

-- 표현식 인덱스
CREATE INDEX idx_reviews_helpful ON reviews (((metadata->>'helpful_count')::INT));

-- 성능 비교
EXPLAIN ANALYZE
SELECT * FROM reviews WHERE metadata @> '{"verified": true}';
-- GIN 인덱스 사용

EXPLAIN ANALYZE
SELECT * FROM reviews WHERE (metadata->>'verified')::BOOLEAN = true;
-- 표현식 인덱스 사용
```

#### JSONB 집계
```sql
-- 태그별 리뷰 수
SELECT
  tag,
  COUNT(*) AS review_count
FROM reviews,
LATERAL jsonb_array_elements_text(metadata->'tags') AS tag
GROUP BY tag
ORDER BY review_count DESC;

-- JSONB 객체 집계
SELECT
  product_id,
  jsonb_agg(
    jsonb_build_object(
      'review_id', review_id,
      'rating', rating,
      'helpful_count', metadata->>'helpful_count'
    )
  ) AS reviews
FROM reviews
GROUP BY product_id;
```

#### 실무 예제: 상품 속성 저장
```sql
-- 상품별로 다른 속성 (노트북 vs 의류)
CREATE TABLE products (
  product_id SERIAL PRIMARY KEY,
  name VARCHAR(255),
  category VARCHAR(100),
  attributes JSONB
);

-- 노트북
INSERT INTO products (name, category, attributes) VALUES
('Dell XPS 13', 'Laptops', '{
  "brand": "Dell",
  "cpu": "Intel i7-1185G7",
  "ram": "16GB",
  "storage": "512GB SSD",
  "screen_size": "13.3 inch",
  "weight_kg": 1.2
}');

-- 의류
INSERT INTO products (name, category, attributes) VALUES
('Cotton T-Shirt', 'Clothing', '{
  "brand": "Generic",
  "material": "100% Cotton",
  "sizes": ["S", "M", "L", "XL"],
  "colors": ["White", "Black", "Blue"],
  "care_instructions": "Machine wash cold"
}');

-- 검색: RAM이 16GB 이상인 노트북
SELECT name, attributes
FROM products
WHERE category = 'Laptops'
  AND (attributes->>'ram')::TEXT LIKE '%16GB%'
  OR (attributes->>'ram')::TEXT LIKE '%32GB%';

-- 검색: 사이즈 L이 있는 의류
SELECT name, attributes
FROM products
WHERE category = 'Clothing'
  AND attributes->'sizes' @> '["L"]';
```

### 9. MERGE 문 (PostgreSQL 15+)

#### MERGE란?
- INSERT, UPDATE, DELETE를 한 번에 처리
- UPSERT (INSERT ... ON CONFLICT)의 확장판
- 조건에 따라 다른 동작 수행

#### 기본 구조
```sql
MERGE INTO target_table t
USING source_table s
ON t.key = s.key
WHEN MATCHED THEN
  UPDATE SET ...
WHEN NOT MATCHED THEN
  INSERT ...
WHEN NOT MATCHED BY SOURCE THEN
  DELETE;
```

#### 재고 동기화 예제
```sql
-- 외부 시스템에서 받은 재고 데이터
CREATE TEMP TABLE inventory_updates (
  variant_id INT,
  new_quantity INT
);

INSERT INTO inventory_updates VALUES
(1, 100),  -- 기존 재고 있음 → UPDATE
(2, 50),   -- 기존 재고 있음 → UPDATE
(999, 25); -- 기존 재고 없음 → INSERT

-- MERGE로 동기화
MERGE INTO inventory t
USING inventory_updates s
ON t.variant_id = s.variant_id
WHEN MATCHED THEN
  UPDATE SET
    quantity = s.new_quantity,
    updated_at = CURRENT_TIMESTAMP
WHEN NOT MATCHED THEN
  INSERT (variant_id, quantity, reserved_quantity, updated_at)
  VALUES (s.variant_id, s.new_quantity, 0, CURRENT_TIMESTAMP);

-- 결과 확인
SELECT * FROM inventory WHERE variant_id IN (1, 2, 999);
```

#### 조건부 UPDATE/DELETE
```sql
-- 재고가 0이면 삭제, 변경되면 업데이트, 없으면 삽입
MERGE INTO inventory t
USING inventory_updates s
ON t.variant_id = s.variant_id
WHEN MATCHED AND s.new_quantity = 0 THEN
  DELETE
WHEN MATCHED THEN
  UPDATE SET
    quantity = s.new_quantity,
    updated_at = CURRENT_TIMESTAMP
WHEN NOT MATCHED AND s.new_quantity > 0 THEN
  INSERT (variant_id, quantity, reserved_quantity, updated_at)
  VALUES (s.variant_id, s.new_quantity, 0, CURRENT_TIMESTAMP);
```

#### RETURNING 절
```sql
-- 변경 사항 추적
MERGE INTO inventory t
USING inventory_updates s
ON t.variant_id = s.variant_id
WHEN MATCHED THEN
  UPDATE SET quantity = s.new_quantity
WHEN NOT MATCHED THEN
  INSERT (variant_id, quantity) VALUES (s.variant_id, s.new_quantity)
RETURNING
  t.variant_id,
  t.quantity AS new_quantity,
  CASE
    WHEN xmax = 0 THEN 'INSERT'
    ELSE 'UPDATE'
  END AS action;
```

### 10. COPY 명령 심화

#### 기본 COPY
```sql
-- CSV 파일 내보내기
COPY (
  SELECT user_id, username, email, created_at
  FROM users
  WHERE created_at >= '2024-01-01'
) TO '/tmp/users_export.csv' WITH (FORMAT CSV, HEADER);

-- CSV 파일 가져오기
COPY users (username, email, phone)
FROM '/tmp/users_import.csv'
WITH (FORMAT CSV, HEADER);
```

#### PostgreSQL 17: ON_ERROR 옵션
```sql
-- 오류 발생 시 해당 행 건너뛰기
COPY products (name, price, stock_quantity)
FROM '/tmp/products.csv'
WITH (
  FORMAT CSV,
  HEADER,
  ON_ERROR ignore  -- PostgreSQL 17 신기능
);

-- 기존 방식: 한 행 오류로 전체 실패
-- 새 방식: 오류 행만 건너뛰고 계속 진행
```

#### COPY vs INSERT 성능
```sql
-- INSERT: 느림
\timing on
INSERT INTO large_table (col1, col2, col3)
SELECT i, 'value' || i, random()
FROM generate_series(1, 1000000) i;
-- Time: 5000 ms

-- COPY: 빠름 (10-100배)
COPY large_table (col1, col2, col3)
FROM PROGRAM 'awk ''BEGIN {for(i=1;i<=1000000;i++) print i "\tvalue" i "\t" rand()}'''
WITH (FORMAT TEXT);
-- Time: 500 ms
```

#### COPY with PROGRAM
```sql
-- 압축 파일 직접 읽기
COPY logs
FROM PROGRAM 'gunzip -c /var/log/app.log.gz'
WITH (FORMAT CSV);

-- 여러 파일 병합
COPY combined_data
FROM PROGRAM 'cat /data/file1.csv /data/file2.csv /data/file3.csv'
WITH (FORMAT CSV, HEADER);

-- S3에서 직접 읽기 (aws-cli 필요)
COPY products
FROM PROGRAM 'aws s3 cp s3://my-bucket/products.csv -'
WITH (FORMAT CSV, HEADER);
```

## 실습 SQL

### 실습 1: Window Functions - 월별 매출 분석

```sql
-- 월별 매출, 누적합, 이동평균, 순위
WITH monthly_sales AS (
  SELECT
    DATE_TRUNC('month', created_at) AS month,
    SUM(total_amount) AS revenue,
    COUNT(*) AS order_count,
    AVG(total_amount) AS avg_order_value
  FROM orders
  WHERE status = 'completed'
    AND created_at >= '2023-01-01'
  GROUP BY DATE_TRUNC('month', created_at)
)
SELECT
  month,
  revenue,
  order_count,
  avg_order_value,
  -- 누적 매출
  SUM(revenue) OVER (ORDER BY month) AS cumulative_revenue,
  -- 전월 대비
  revenue - LAG(revenue) OVER (ORDER BY month) AS mom_change,
  ROUND(
    (revenue - LAG(revenue) OVER (ORDER BY month)) /
    NULLIF(LAG(revenue) OVER (ORDER BY month), 0) * 100,
    2
  ) AS mom_growth_pct,
  -- 3개월 이동평균
  ROUND(
    AVG(revenue) OVER (
      ORDER BY month
      ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ),
    2
  ) AS moving_avg_3m,
  -- 매출 순위
  RANK() OVER (ORDER BY revenue DESC) AS revenue_rank,
  -- 전체 대비 비율
  ROUND(revenue / SUM(revenue) OVER () * 100, 2) AS pct_of_total
FROM monthly_sales
ORDER BY month;
```

### 실습 2: Recursive CTE - 카테고리 트리

```sql
-- 전체 카테고리 계층 구조
WITH RECURSIVE category_tree AS (
  -- Anchor: 최상위 카테고리
  SELECT
    category_id,
    name,
    parent_category_id,
    level,
    name::TEXT AS path,
    name::TEXT AS breadcrumb,
    ARRAY[category_id] AS id_path
  FROM categories
  WHERE parent_category_id IS NULL

  UNION ALL

  -- Recursive: 하위 카테고리
  SELECT
    c.category_id,
    c.name,
    c.parent_category_id,
    c.level,
    ct.path || ' > ' || c.name,
    ct.breadcrumb || ' / ' || c.name,
    ct.id_path || c.category_id
  FROM categories c
  JOIN category_tree ct ON c.parent_category_id = ct.category_id
)
SELECT
  REPEAT('  ', level) || name AS tree_view,
  breadcrumb,
  level,
  id_path
FROM category_tree
ORDER BY path;

-- 특정 카테고리의 모든 상품 (하위 카테고리 포함)
WITH RECURSIVE subcategories AS (
  SELECT category_id
  FROM categories
  WHERE category_id = 2  -- Computers

  UNION ALL

  SELECT c.category_id
  FROM categories c
  JOIN subcategories sc ON c.parent_category_id = sc.category_id
)
SELECT
  p.product_id,
  p.name,
  c.name AS category_name
FROM products p
JOIN categories c ON p.category_id = c.category_id
WHERE p.category_id IN (SELECT category_id FROM subcategories);
```

### 실습 3: LATERAL JOIN - Top-N per Group

```sql
-- 각 사용자의 최근 3개 주문과 주문 상세
SELECT
  u.user_id,
  u.username,
  recent_orders.order_id,
  recent_orders.created_at,
  recent_orders.total_amount,
  recent_orders.item_count
FROM users u
CROSS JOIN LATERAL (
  SELECT
    o.order_id,
    o.created_at,
    o.total_amount,
    COUNT(oi.order_item_id) AS item_count
  FROM orders o
  LEFT JOIN order_items oi ON o.order_id = oi.order_id
  WHERE o.user_id = u.user_id
  GROUP BY o.order_id, o.created_at, o.total_amount
  ORDER BY o.created_at DESC
  LIMIT 3
) AS recent_orders
WHERE u.created_at >= '2024-01-01'
ORDER BY u.user_id, recent_orders.created_at DESC;

-- 각 카테고리의 베스트셀러 + 리뷰 통계
SELECT
  c.name AS category_name,
  top_products.product_name,
  top_products.total_sold,
  top_products.revenue,
  review_stats.avg_rating,
  review_stats.review_count
FROM categories c
CROSS JOIN LATERAL (
  SELECT
    p.product_id,
    p.name AS product_name,
    SUM(oi.quantity) AS total_sold,
    SUM(oi.quantity * oi.price) AS revenue
  FROM products p
  JOIN product_variants pv ON p.product_id = pv.product_id
  JOIN order_items oi ON pv.variant_id = oi.variant_id
  JOIN orders o ON oi.order_id = o.order_id
  WHERE p.category_id = c.category_id
    AND o.status = 'completed'
  GROUP BY p.product_id, p.name
  ORDER BY SUM(oi.quantity * oi.price) DESC
  LIMIT 5
) AS top_products
LEFT JOIN LATERAL (
  SELECT
    ROUND(AVG(rating)::NUMERIC, 2) AS avg_rating,
    COUNT(*) AS review_count
  FROM reviews
  WHERE product_id = top_products.product_id
) AS review_stats ON TRUE
ORDER BY c.name, top_products.revenue DESC;
```

### 실습 4: GROUPING SETS - 다차원 집계

```sql
-- 카테고리, 상태, 결제방법별 매출 (모든 조합)
SELECT
  COALESCE(c.name, '(All Categories)') AS category,
  COALESCE(o.status, '(All Statuses)') AS status,
  COALESCE(p.payment_method, '(All Methods)') AS payment_method,
  COUNT(DISTINCT o.order_id) AS order_count,
  SUM(o.total_amount) AS total_revenue,
  AVG(o.total_amount) AS avg_order_value,
  GROUPING(c.name) AS is_all_categories,
  GROUPING(o.status) AS is_all_statuses,
  GROUPING(p.payment_method) AS is_all_methods
FROM orders o
LEFT JOIN payments p ON o.order_id = p.order_id
LEFT JOIN order_items oi ON o.order_id = oi.order_id
LEFT JOIN product_variants pv ON oi.variant_id = pv.variant_id
LEFT JOIN products pr ON pv.product_id = pr.product_id
LEFT JOIN categories c ON pr.category_id = c.category_id
WHERE o.created_at >= '2024-01-01'
GROUP BY GROUPING SETS (
  (c.name, o.status, p.payment_method),  -- 세부
  (c.name, o.status),                    -- 카테고리+상태
  (c.name, p.payment_method),            -- 카테고리+결제방법
  (o.status, p.payment_method),          -- 상태+결제방법
  (c.name),                              -- 카테고리별
  (o.status),                            -- 상태별
  (p.payment_method),                    -- 결제방법별
  ()                                     -- 전체
)
ORDER BY
  GROUPING(c.name),
  GROUPING(o.status),
  GROUPING(p.payment_method),
  category,
  status,
  payment_method;
```

### 실습 5: JSON/JSONB - 리뷰 메타데이터 분석

```sql
-- 리뷰 메타데이터 집계
SELECT
  product_id,
  COUNT(*) AS total_reviews,
  ROUND(AVG(rating)::NUMERIC, 2) AS avg_rating,
  -- JSONB 필드 집계
  ROUND(AVG((metadata->>'helpful_count')::INT), 2) AS avg_helpful_count,
  SUM(CASE WHEN (metadata->>'verified')::BOOLEAN THEN 1 ELSE 0 END) AS verified_count,
  -- 태그 집계
  jsonb_agg(DISTINCT tag) FILTER (WHERE tag IS NOT NULL) AS all_tags
FROM reviews,
LATERAL jsonb_array_elements_text(metadata->'tags') AS tag
GROUP BY product_id
HAVING COUNT(*) >= 5
ORDER BY avg_rating DESC;

-- PostgreSQL 17: JSON_TABLE 사용
SELECT
  r.product_id,
  r.review_id,
  r.rating,
  jt.helpful_count,
  jt.verified,
  jt.tag
FROM reviews r,
JSON_TABLE(
  r.metadata,
  '$.tags[*]' COLUMNS (
    helpful_count INT PATH '$.helpful_count',
    verified BOOLEAN PATH '$.verified',
    tag TEXT PATH '$'
  )
) AS jt
WHERE jt.verified = true
  AND jt.helpful_count > 10
ORDER BY jt.helpful_count DESC;
```

### 실습 6: MERGE - 재고 동기화

```sql
-- 외부 시스템에서 재고 업데이트
CREATE TEMP TABLE inventory_sync (
  variant_id INT,
  quantity INT,
  last_updated TIMESTAMP
);

INSERT INTO inventory_sync VALUES
(1, 150, '2024-01-20 10:00:00'),
(2, 75, '2024-01-20 10:00:00'),
(3, 0, '2024-01-20 10:00:00'),  -- 재고 0 → 삭제
(999, 50, '2024-01-20 10:00:00'); -- 신규

-- MERGE로 동기화
MERGE INTO inventory t
USING inventory_sync s
ON t.variant_id = s.variant_id
WHEN MATCHED AND s.quantity = 0 THEN
  DELETE
WHEN MATCHED THEN
  UPDATE SET
    quantity = s.quantity,
    updated_at = s.last_updated
WHEN NOT MATCHED AND s.quantity > 0 THEN
  INSERT (variant_id, quantity, reserved_quantity, updated_at)
  VALUES (s.variant_id, s.quantity, 0, s.last_updated)
RETURNING
  variant_id,
  quantity,
  CASE
    WHEN xmax = 0 THEN 'INSERTED'
    WHEN quantity IS NULL THEN 'DELETED'
    ELSE 'UPDATED'
  END AS action;
```

## 직접 확인해보기

### 1. Window Frame 비교
```sql
-- 동일 쿼리, 다른 프레임
SELECT
  created_at::DATE AS day,
  total_amount,
  -- ROWS: 물리적 3행
  AVG(total_amount) OVER (
    ORDER BY created_at
    ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
  ) AS moving_avg_rows,
  -- RANGE: 논리적 3일
  AVG(total_amount) OVER (
    ORDER BY created_at::DATE
    RANGE BETWEEN INTERVAL '2 days' PRECEDING AND CURRENT ROW
  ) AS moving_avg_range
FROM orders
WHERE created_at >= '2024-01-01'
ORDER BY created_at
LIMIT 20;
```

### 2. LATERAL vs Window Function 성능
```sql
-- 성능 비교
EXPLAIN ANALYZE
-- LATERAL 방식
SELECT u.user_id, recent.order_id
FROM users u
CROSS JOIN LATERAL (
  SELECT order_id FROM orders WHERE user_id = u.user_id
  ORDER BY created_at DESC LIMIT 3
) recent;

EXPLAIN ANALYZE
-- Window Function 방식
WITH ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) AS rn
  FROM orders
)
SELECT user_id, order_id FROM ranked WHERE rn <= 3;
```

### 3. JSONB 인덱스 효과
```sql
-- 인덱스 없이
EXPLAIN ANALYZE
SELECT * FROM reviews
WHERE metadata @> '{"verified": true}';

-- GIN 인덱스 생성
CREATE INDEX idx_reviews_metadata_gin ON reviews USING GIN (metadata);

-- 인덱스 사용 확인
EXPLAIN ANALYZE
SELECT * FROM reviews
WHERE metadata @> '{"verified": true}';
```

## 실무 팁

### 1. Window Function 사용 시 주의
```sql
-- ❌ 여러 번 계산
SELECT
  order_id,
  total_amount,
  total_amount - AVG(total_amount) OVER () AS diff,
  total_amount / AVG(total_amount) OVER () AS ratio
FROM orders;

-- ✅ CTE로 한 번만 계산
WITH stats AS (
  SELECT AVG(total_amount) AS avg_amount FROM orders
)
SELECT
  order_id,
  total_amount,
  total_amount - stats.avg_amount AS diff,
  total_amount / stats.avg_amount AS ratio
FROM orders, stats;
```

### 2. Recursive CTE 무한 루프 방지
```sql
-- ❌ 순환 참조 시 무한 루프
WITH RECURSIVE cycle_detect AS (
  SELECT category_id, parent_category_id, ARRAY[category_id] AS path
  FROM categories WHERE category_id = 1
  UNION ALL
  SELECT c.category_id, c.parent_category_id, cd.path || c.category_id
  FROM categories c
  JOIN cycle_detect cd ON c.parent_category_id = cd.category_id
  -- 여기서 멈추지 않으면 무한 루프
)
SELECT * FROM cycle_detect;

-- ✅ 순환 감지
WITH RECURSIVE cycle_detect AS (
  SELECT category_id, parent_category_id, ARRAY[category_id] AS path, FALSE AS is_cycle
  FROM categories WHERE category_id = 1
  UNION ALL
  SELECT
    c.category_id,
    c.parent_category_id,
    cd.path || c.category_id,
    c.category_id = ANY(cd.path) AS is_cycle
  FROM categories c
  JOIN cycle_detect cd ON c.parent_category_id = cd.category_id
  WHERE NOT cd.is_cycle  -- 순환 감지 시 중단
)
SELECT * FROM cycle_detect;
```

### 3. JSONB vs 정규화 선택
```sql
-- JSONB 적합: 스키마 유동적, 조회 드문 경우
-- 예: 상품 메타데이터, 이벤트 로그

-- 정규화 적합: 자주 검색/필터, 관계 명확
-- 예: 주문-상품 관계, 사용자-주소
```

### 4. MERGE vs INSERT ... ON CONFLICT
```sql
-- 단순 UPSERT: INSERT ... ON CONFLICT
INSERT INTO inventory (variant_id, quantity)
VALUES (1, 100)
ON CONFLICT (variant_id)
DO UPDATE SET quantity = EXCLUDED.quantity;

-- 복잡한 동기화: MERGE
-- - 조건부 UPDATE/DELETE
-- - NOT MATCHED BY SOURCE (소스에 없는 것 삭제)
-- - 여러 WHEN 절
```

### 5. COPY 성능 최적화
```sql
-- 대량 INSERT 전
-- 1. 인덱스 비활성화 고려
DROP INDEX idx_table_column;
COPY ... ;
CREATE INDEX idx_table_column ON ...;

-- 2. 제약조건 임시 비활성화
ALTER TABLE table DISABLE TRIGGER ALL;
COPY ... ;
ALTER TABLE table ENABLE TRIGGER ALL;

-- 3. WAL 수준 낮추기 (복제 없는 경우)
ALTER TABLE table SET UNLOGGED;
COPY ... ;
ALTER TABLE table SET LOGGED;
```

### 6. CTE 최적화 (PostgreSQL 17)
```sql
-- PostgreSQL 17: 자동으로 최적화
-- 명시적 MATERIALIZED 불필요
WITH recent_orders AS (
  SELECT * FROM orders WHERE created_at >= CURRENT_DATE - 7
)
SELECT ... FROM recent_orders;

-- 강제 Materialize가 필요한 경우만
WITH data AS MATERIALIZED (
  SELECT expensive_calculation() ...
)
SELECT ... FROM data
UNION ALL
SELECT ... FROM data;  -- 두 번 사용 → Materialize 유리
```

## 참고 링크

### 공식 문서
- [PostgreSQL 17 Documentation - Queries](https://www.postgresql.org/docs/17/queries.html)
- [Chapter 7. Queries](https://www.postgresql.org/docs/17/queries.html)
- [Chapter 9. Functions and Operators](https://www.postgresql.org/docs/17/functions.html)
- [Window Functions](https://www.postgresql.org/docs/17/tutorial-window.html)
- [WITH Queries (CTE)](https://www.postgresql.org/docs/17/queries-with.html)

### PostgreSQL 17 신기능
- [JSON Functions (JSON_TABLE, JSON_EXISTS, etc.)](https://www.postgresql.org/docs/17/functions-json.html)
- [COPY ON_ERROR](https://www.postgresql.org/docs/17/sql-copy.html)
- [MERGE Statement](https://www.postgresql.org/docs/17/sql-merge.html)

### 심화 학습
- [Window Functions Tutorial](https://www.postgresql.org/docs/17/tutorial-window.html)
- [Recursive Queries](https://www.postgresql.org/docs/17/queries-with.html#QUERIES-WITH-RECURSIVE)
- [LATERAL Subqueries](https://www.postgresql.org/docs/17/queries-table-expressions.html#QUERIES-LATERAL)
- [JSONB Indexing](https://www.postgresql.org/docs/17/datatype-json.html#JSON-INDEXING)

### 관련 노트
- `07-query-optimization.md`: 쿼리 최적화
- `08-data-modeling.md`: 데이터 모델링
- `03-indexing.md`: 인덱스 전략

### 도구 및 리소스
- [PostgreSQL Exercises](https://pgexercises.com/) - Window Functions 연습
- [SQL Fiddle](http://sqlfiddle.com/) - 온라인 SQL 테스트
- [Modern SQL](https://modern-sql.com/) - 최신 SQL 기능 소개

---

**다음 노트**: `10-advanced-features.md` - 고급 기능 (계획)
**이전 노트**: `08-data-modeling.md` - 데이터 모델링과 스키마 설계
