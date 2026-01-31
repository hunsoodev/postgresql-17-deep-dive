# 08. 데이터 모델링과 스키마 설계

## 한줄 요약
효율적이고 확장 가능한 데이터베이스를 위한 정규화/반정규화 원칙, 데이터 타입 선택, 제약조건, 관계 패턴을 다룬다.

## 왜 알아야 하는가

### 데이터 모델링의 중요성
- 잘못된 스키마 설계는 나중에 수정하기 매우 어렵고 비용이 큼
- 초기 설계가 애플리케이션 전체 성능과 유지보수성 결정
- 정규화와 반정규화의 균형이 필요함

### 실무에서의 영향
```
잘못된 설계:
- 데이터 중복으로 인한 불일치
- 비효율적인 쿼리 (과도한 조인)
- 확장 어려움
- 마이그레이션 고통

올바른 설계:
- 데이터 무결성 보장
- 최적화된 쿼리 성능
- 유연한 확장
- 명확한 비즈니스 로직
```

### PostgreSQL 17에서의 데이터 모델링
- 향상된 파티셔닝 기능
- JSON/JSONB 성능 개선 (JSON_TABLE 등)
- 제약조건 성능 향상
- 더 나은 타입 시스템 지원

## 핵심 개념

### 1. 정규화 (Normalization)

#### 정규화의 목적
- **데이터 중복 최소화**: 저장 공간 절약, 일관성 유지
- **갱신 이상 방지**: 삽입/수정/삭제 시 문제 제거
- **데이터 무결성 강화**: 논리적 오류 방지

#### 비정규화 테이블 예시 (이커머스)
```sql
-- 정규화되지 않은 주문 테이블
CREATE TABLE orders_denormalized (
  order_id SERIAL PRIMARY KEY,
  order_date TIMESTAMP,

  -- 사용자 정보 (중복)
  user_id INT,
  username VARCHAR(100),
  user_email VARCHAR(255),
  user_phone VARCHAR(20),

  -- 배송지 정보 (중복)
  shipping_address VARCHAR(500),
  shipping_city VARCHAR(100),
  shipping_zipcode VARCHAR(10),

  -- 주문 상품 정보 (배열로 저장하면 1NF 위반)
  product_ids INT[],
  product_names TEXT[],
  quantities INT[],
  prices DECIMAL(10,2)[],

  -- 결제 정보 (중복)
  payment_method VARCHAR(50),
  payment_status VARCHAR(50),

  total_amount DECIMAL(10,2)
);
```

문제점:
1. 사용자 정보 중복 → 이메일 변경 시 모든 주문 업데이트 필요
2. 배열 사용 → 상품별 조회 어려움, 인덱싱 불가
3. 상품 가격 중복 → 가격 히스토리 추적 어려움
4. 데이터 일관성 보장 어려움

### 2. 정규화 단계별 설명

#### 제1정규형 (1NF): 원자값

**규칙**: 각 컬럼은 원자값(더 이상 나눌 수 없는 값)을 가져야 함

```sql
-- ❌ 1NF 위반: 배열 사용
CREATE TABLE orders_0nf (
  order_id INT PRIMARY KEY,
  product_ids INT[],        -- 원자값 아님
  quantities INT[]
);

-- ✅ 1NF 준수: 주문-상품 분리
CREATE TABLE orders_1nf (
  order_id INT PRIMARY KEY,
  order_date TIMESTAMP,
  user_id INT,
  total_amount DECIMAL(10,2)
);

CREATE TABLE order_items_1nf (
  order_item_id SERIAL PRIMARY KEY,
  order_id INT REFERENCES orders_1nf(order_id),
  product_id INT,
  quantity INT,
  price DECIMAL(10,2)
);
```

**1NF 변환 실습**:
```sql
-- 비정규화 데이터
INSERT INTO orders_0nf VALUES
(1, ARRAY[101, 102, 103], ARRAY[2, 1, 5]);

-- 1NF로 변환
INSERT INTO orders_1nf (order_id, order_date, user_id, total_amount)
VALUES (1, NOW(), 1001, 0);

INSERT INTO order_items_1nf (order_id, product_id, quantity, price)
VALUES
  (1, 101, 2, 29.99),
  (1, 102, 1, 49.99),
  (1, 103, 5, 9.99);

-- 조회는 JOIN 필요
SELECT o.order_id, oi.product_id, oi.quantity
FROM orders_1nf o
JOIN order_items_1nf oi ON o.order_id = oi.order_id
WHERE o.order_id = 1;
```

#### 제2정규형 (2NF): 부분 함수 종속 제거

**규칙**: 기본키가 복합키일 때, 모든 컬럼이 기본키 전체에 종속되어야 함

```sql
-- ❌ 2NF 위반: 부분 종속 존재
CREATE TABLE order_items_1nf_only (
  order_id INT,
  product_id INT,
  quantity INT,
  price DECIMAL(10,2),
  product_name VARCHAR(255),    -- product_id에만 종속
  product_category VARCHAR(100), -- product_id에만 종속
  PRIMARY KEY (order_id, product_id)
);

-- 문제: product_name, product_category는 product_id에만 종속
-- 같은 상품이 여러 주문에 있으면 중복 저장

-- ✅ 2NF 준수: 부분 종속 제거
CREATE TABLE order_items_2nf (
  order_id INT,
  product_id INT,
  quantity INT,
  price DECIMAL(10,2),
  PRIMARY KEY (order_id, product_id)
);

CREATE TABLE products_2nf (
  product_id INT PRIMARY KEY,
  product_name VARCHAR(255),
  category VARCHAR(100)
);
```

**2NF 변환 실습**:
```sql
-- 1NF 데이터에서 2NF로 변환
-- 중복된 상품 정보 추출
INSERT INTO products_2nf (product_id, product_name, category)
SELECT DISTINCT product_id, product_name, product_category
FROM order_items_1nf_only;

-- order_items는 순수하게 주문-상품 관계만
INSERT INTO order_items_2nf (order_id, product_id, quantity, price)
SELECT order_id, product_id, quantity, price
FROM order_items_1nf_only;
```

#### 제3정규형 (3NF): 이행 함수 종속 제거

**규칙**: 기본키가 아닌 컬럼 간 종속 제거

```sql
-- ❌ 3NF 위반: 이행 종속 존재
CREATE TABLE orders_2nf_only (
  order_id INT PRIMARY KEY,
  user_id INT,
  username VARCHAR(100),     -- user_id → username (이행 종속)
  user_email VARCHAR(255),   -- user_id → user_email
  shipping_address_id INT,
  shipping_address_text VARCHAR(500),  -- address_id → address_text
  total_amount DECIMAL(10,2)
);

-- 문제: user_id → username, email (기본키 order_id를 거쳐 종속)
-- 사용자 정보 변경 시 모든 주문 업데이트 필요

-- ✅ 3NF 준수: 이행 종속 제거
CREATE TABLE users (
  user_id SERIAL PRIMARY KEY,
  username VARCHAR(100) NOT NULL UNIQUE,
  email VARCHAR(255) NOT NULL UNIQUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE addresses (
  address_id SERIAL PRIMARY KEY,
  user_id INT REFERENCES users(user_id),
  address_line1 VARCHAR(255) NOT NULL,
  address_line2 VARCHAR(255),
  city VARCHAR(100) NOT NULL,
  zipcode VARCHAR(10) NOT NULL,
  is_default BOOLEAN DEFAULT FALSE
);

CREATE TABLE orders (
  order_id SERIAL PRIMARY KEY,
  user_id INT REFERENCES users(user_id),
  shipping_address_id INT REFERENCES addresses(address_id),
  total_amount DECIMAL(10,2),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**3NF 변환 실습**:
```sql
-- 사용자 정보 추출
INSERT INTO users (user_id, username, user_email)
SELECT DISTINCT user_id, username, user_email
FROM orders_2nf_only;

-- 주소 정보 추출
INSERT INTO addresses (address_id, user_id, address_line1)
SELECT DISTINCT
  shipping_address_id,
  user_id,
  shipping_address_text
FROM orders_2nf_only;

-- 주문 테이블은 FK만 유지
INSERT INTO orders (order_id, user_id, shipping_address_id, total_amount)
SELECT order_id, user_id, shipping_address_id, total_amount
FROM orders_2nf_only;

-- 조회는 JOIN
SELECT
  o.order_id,
  u.username,
  u.email,
  a.address_line1,
  o.total_amount
FROM orders o
JOIN users u ON o.user_id = u.user_id
JOIN addresses a ON o.shipping_address_id = a.address_id
WHERE o.order_id = 1;
```

#### BCNF (Boyce-Codd Normal Form): 후보키 종속

**규칙**: 모든 결정자가 후보키여야 함

```sql
-- ❌ BCNF 위반 예시
CREATE TABLE course_instructor (
  course_id VARCHAR(10),
  instructor_id INT,
  instructor_office VARCHAR(20),  -- instructor_id → office
  PRIMARY KEY (course_id, instructor_id)
);

-- 문제: instructor_id → instructor_office 이지만
-- instructor_id는 후보키가 아님

-- ✅ BCNF 준수
CREATE TABLE instructors (
  instructor_id INT PRIMARY KEY,
  instructor_office VARCHAR(20)
);

CREATE TABLE course_assignments (
  course_id VARCHAR(10),
  instructor_id INT REFERENCES instructors(instructor_id),
  PRIMARY KEY (course_id, instructor_id)
);
```

**이커머스 예시**:
```sql
-- ❌ BCNF 위반
CREATE TABLE product_suppliers (
  product_id INT,
  supplier_id INT,
  supplier_email VARCHAR(255),  -- supplier_id → email
  PRIMARY KEY (product_id, supplier_id)
);

-- ✅ BCNF 준수
CREATE TABLE suppliers (
  supplier_id SERIAL PRIMARY KEY,
  supplier_name VARCHAR(255) NOT NULL,
  email VARCHAR(255) UNIQUE NOT NULL
);

CREATE TABLE product_suppliers_bcnf (
  product_id INT REFERENCES products(product_id),
  supplier_id INT REFERENCES suppliers(supplier_id),
  supply_price DECIMAL(10,2),
  PRIMARY KEY (product_id, supplier_id)
);
```

#### 제4정규형 (4NF): 다치 종속 제거

**규칙**: 다치 종속이 있으면 별도 테이블로 분리

```sql
-- ❌ 4NF 위반: 다치 종속
CREATE TABLE employee_skills_languages (
  employee_id INT,
  skill VARCHAR(100),
  language VARCHAR(50),
  PRIMARY KEY (employee_id, skill, language)
);

-- 문제: employee가 skill과 language를 독립적으로 가짐
-- 예: employee_id=1, skills={Java, Python}, languages={EN, KR}
-- 조합: (1, Java, EN), (1, Java, KR), (1, Python, EN), (1, Python, KR)
-- 불필요한 중복

-- ✅ 4NF 준수: 다치 종속 분리
CREATE TABLE employee_skills (
  employee_id INT,
  skill VARCHAR(100),
  PRIMARY KEY (employee_id, skill)
);

CREATE TABLE employee_languages (
  employee_id INT,
  language VARCHAR(50),
  PRIMARY KEY (employee_id, language)
);
```

**이커머스 예시**:
```sql
-- ❌ 4NF 위반
CREATE TABLE product_tags_categories (
  product_id INT,
  tag VARCHAR(50),
  category VARCHAR(50),
  PRIMARY KEY (product_id, tag, category)
);

-- 문제: 상품이 여러 태그와 여러 카테고리를 독립적으로 가짐

-- ✅ 4NF 준수
CREATE TABLE product_tags (
  product_id INT REFERENCES products(product_id),
  tag VARCHAR(50),
  PRIMARY KEY (product_id, tag)
);

CREATE TABLE product_categories_mapping (
  product_id INT REFERENCES products(product_id),
  category_id INT REFERENCES categories(category_id),
  PRIMARY KEY (product_id, category_id)
);
```

#### 제5정규형 (5NF): 조인 종속

**규칙**: 조인 종속을 만족하도록 분해

```sql
-- ❌ 5NF 위반
CREATE TABLE project_assignments (
  employee_id INT,
  project_id INT,
  role VARCHAR(50),
  PRIMARY KEY (employee_id, project_id, role)
);

-- 제약: employee가 role을 가지고, project가 role을 요구하면
-- employee-project-role 조합 자동 생성

-- ✅ 5NF 준수
CREATE TABLE employee_roles (
  employee_id INT,
  role VARCHAR(50),
  PRIMARY KEY (employee_id, role)
);

CREATE TABLE project_role_requirements (
  project_id INT,
  role VARCHAR(50),
  PRIMARY KEY (project_id, role)
);

CREATE TABLE project_assignments_5nf (
  employee_id INT,
  project_id INT,
  role VARCHAR(50),
  PRIMARY KEY (employee_id, project_id, role),
  FOREIGN KEY (employee_id, role) REFERENCES employee_roles(employee_id, role),
  FOREIGN KEY (project_id, role) REFERENCES project_role_requirements(project_id, role)
);
```

실무에서는 3NF~BCNF까지만 사용하는 경우가 대부분입니다.

### 3. 반정규화 (Denormalization)

#### 반정규화를 고려하는 경우

1. **읽기 성능이 매우 중요한 경우**
   - 복잡한 JOIN이 성능 병목
   - 자주 조회되지만 거의 변경되지 않는 데이터

2. **집계 쿼리가 빈번한 경우**
   - 실시간 집계가 느린 경우
   - Materialized View 활용

3. **특정 패턴의 쿼리가 지배적인 경우**
   - 특정 조회 패턴에 최적화

#### 반정규화 기법

##### 1) 컬럼 중복
```sql
-- 정규화된 스키마
CREATE TABLE orders (
  order_id SERIAL PRIMARY KEY,
  user_id INT REFERENCES users(user_id),
  total_amount DECIMAL(10,2)
);

CREATE TABLE users (
  user_id SERIAL PRIMARY KEY,
  username VARCHAR(100),
  email VARCHAR(255)
);

-- ❌ 자주 필요한 JOIN
SELECT o.order_id, u.username, o.total_amount
FROM orders o
JOIN users u ON o.user_id = u.user_id;

-- ✅ 반정규화: username 중복 저장
CREATE TABLE orders_denorm (
  order_id SERIAL PRIMARY KEY,
  user_id INT REFERENCES users(user_id),
  username VARCHAR(100),  -- 중복
  total_amount DECIMAL(10,2)
);

-- 트리거로 일관성 유지
CREATE OR REPLACE FUNCTION sync_username()
RETURNS TRIGGER AS $$
BEGIN
  NEW.username := (SELECT username FROM users WHERE user_id = NEW.user_id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_username
BEFORE INSERT OR UPDATE ON orders_denorm
FOR EACH ROW EXECUTE FUNCTION sync_username();
```

##### 2) 집계 컬럼 추가
```sql
-- 정규화: 주문 아이템 개수를 매번 COUNT
SELECT o.*, COUNT(oi.order_item_id) AS item_count
FROM orders o
LEFT JOIN order_items oi ON o.order_id = oi.order_id
GROUP BY o.order_id;

-- 반정규화: item_count 컬럼 추가
ALTER TABLE orders ADD COLUMN item_count INT DEFAULT 0;

-- 트리거로 자동 갱신
CREATE OR REPLACE FUNCTION update_order_item_count()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE orders SET item_count = item_count + 1 WHERE order_id = NEW.order_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE orders SET item_count = item_count - 1 WHERE order_id = OLD.order_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_item_count_insert
AFTER INSERT ON order_items
FOR EACH ROW EXECUTE FUNCTION update_order_item_count();

CREATE TRIGGER trg_update_item_count_delete
AFTER DELETE ON order_items
FOR EACH ROW EXECUTE FUNCTION update_order_item_count();
```

##### 3) Materialized View 활용
```sql
-- 복잡한 집계 쿼리
CREATE MATERIALIZED VIEW mv_product_sales_summary AS
SELECT
  p.product_id,
  p.name AS product_name,
  c.name AS category_name,
  COUNT(DISTINCT oi.order_id) AS order_count,
  SUM(oi.quantity) AS total_quantity_sold,
  SUM(oi.quantity * oi.price) AS total_revenue,
  AVG(oi.price) AS avg_price,
  MAX(o.created_at) AS last_order_date
FROM products p
JOIN categories c ON p.category_id = c.category_id
JOIN product_variants pv ON p.product_id = pv.product_id
JOIN order_items oi ON pv.variant_id = oi.variant_id
JOIN orders o ON oi.order_id = o.order_id
WHERE o.status = 'completed'
GROUP BY p.product_id, p.name, c.name;

-- 인덱스 추가
CREATE INDEX idx_mv_product_sales_product_id
ON mv_product_sales_summary(product_id);

CREATE INDEX idx_mv_product_sales_category
ON mv_product_sales_summary(category_name);

-- 정기적으로 갱신
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_product_sales_summary;

-- 조회는 매우 빠름
SELECT * FROM mv_product_sales_summary
WHERE category_name = 'Electronics'
ORDER BY total_revenue DESC
LIMIT 10;
```

PostgreSQL 17에서는 Incremental Materialized View Maintenance를 위한 기반 작업이 진행 중입니다.

### 4. 데이터 타입 선택 가이드

#### 정수형 타입
```sql
-- 크기에 따른 선택
CREATE TABLE type_examples (
  -- SMALLINT: -32768 ~ 32767 (2 bytes)
  age SMALLINT,                    -- 나이, 수량 등

  -- INTEGER: -2147483648 ~ 2147483647 (4 bytes)
  user_id INTEGER,                 -- 대부분의 ID

  -- BIGINT: -9223372036854775808 ~ 9223372036854775807 (8 bytes)
  order_id BIGINT,                 -- 대용량 서비스의 ID

  -- SERIAL (자동 증가)
  id SERIAL PRIMARY KEY,           -- INTEGER + SEQUENCE
  big_id BIGSERIAL                 -- BIGINT + SEQUENCE
);

-- 타입 크기 확인
SELECT
  pg_column_size(123::SMALLINT) AS smallint_size,  -- 2
  pg_column_size(123::INTEGER) AS integer_size,    -- 4
  pg_column_size(123::BIGINT) AS bigint_size;      -- 8
```

선택 기준:
- **SMALLINT**: 범위가 확실히 작은 경우 (나이, 소량 재고 등)
- **INTEGER**: 기본 선택, 21억까지면 충분
- **BIGINT**: 대용량 서비스, 미래 확장 고려 시

#### 문자열 타입
```sql
CREATE TABLE string_examples (
  -- VARCHAR(n): 가변 길이, 최대 n
  username VARCHAR(100),           -- 사용자명 (제한 필요)
  email VARCHAR(255),              -- 이메일 (표준 길이)

  -- TEXT: 무제한 가변 길이
  description TEXT,                -- 상품 설명 (길이 예측 불가)
  review_content TEXT,             -- 리뷰 내용

  -- CHAR(n): 고정 길이 (공백 패딩)
  country_code CHAR(2),            -- ISO 국가 코드 (항상 2자)
  status_code CHAR(1)              -- 상태 코드 (항상 1자)
);
```

선택 기준:
- **VARCHAR(n)**: 길이 제한이 있는 경우 (제약조건 역할)
- **TEXT**: 길이 예측 불가능한 경우
- **CHAR(n)**: 항상 고정 길이인 경우 (성능상 큰 차이 없음)

#### 숫자형 타입
```sql
CREATE TABLE numeric_examples (
  -- NUMERIC(precision, scale): 정확한 소수
  price NUMERIC(10, 2),            -- 가격: 최대 99999999.99
  tax_rate NUMERIC(5, 4),          -- 세율: 0.0000 ~ 9.9999

  -- DECIMAL: NUMERIC의 별칭
  total_amount DECIMAL(12, 2),

  -- REAL: 4 bytes 부동소수점
  weight_kg REAL,                  -- 무게 (근사값)

  -- DOUBLE PRECISION: 8 bytes 부동소수점
  latitude DOUBLE PRECISION,       -- 위도
  longitude DOUBLE PRECISION       -- 경도
);
```

선택 기준:
- **NUMERIC/DECIMAL**: 정확한 계산 필요 (금액, 세금 등)
- **REAL/DOUBLE**: 과학 계산, 근사값 허용 (통계, 좌표 등)

주의: 금액은 절대 REAL/DOUBLE 사용 금지 (부동소수점 오차)

#### 날짜/시간 타입
```sql
CREATE TABLE datetime_examples (
  -- DATE: 날짜만
  birth_date DATE,                 -- 생년월일

  -- TIME: 시간만
  business_hours_start TIME,       -- 영업 시작 시간

  -- TIMESTAMP: 날짜+시간 (타임존 없음)
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  -- TIMESTAMPTZ: 날짜+시간+타임존
  event_time TIMESTAMPTZ,          -- 글로벌 서비스는 이것 사용

  -- INTERVAL: 시간 간격
  delivery_duration INTERVAL       -- 배송 소요 시간
);

-- TIMESTAMPTZ 예시
INSERT INTO datetime_examples (event_time)
VALUES ('2024-01-15 14:30:00+09');  -- KST

SELECT event_time AT TIME ZONE 'UTC',
       event_time AT TIME ZONE 'America/New_York'
FROM datetime_examples;
```

선택 기준:
- **TIMESTAMPTZ**: 글로벌 서비스는 항상 이것 (타임존 자동 변환)
- **TIMESTAMP**: 타임존이 명확한 로컬 서비스
- **DATE**: 날짜만 필요한 경우

#### Boolean 타입
```sql
CREATE TABLE boolean_examples (
  is_active BOOLEAN DEFAULT TRUE,
  is_deleted BOOLEAN DEFAULT FALSE,
  email_verified BOOLEAN
);

-- Boolean 조회
SELECT * FROM users WHERE is_active = TRUE;
SELECT * FROM users WHERE is_active;  -- 동일
SELECT * FROM users WHERE NOT is_deleted;
```

#### JSON/JSONB 타입
```sql
CREATE TABLE json_examples (
  -- JSON: 텍스트 저장, 입력 빠름
  metadata JSON,

  -- JSONB: 바이너리 저장, 조회/인덱싱 빠름 (권장)
  attributes JSONB,
  settings JSONB
);

-- JSONB 사용 예시
INSERT INTO products (name, attributes)
VALUES ('Laptop', '{"brand": "Dell", "ram": "16GB", "cpu": "i7"}');

-- JSONB 조회
SELECT * FROM products
WHERE attributes->>'brand' = 'Dell';

SELECT * FROM products
WHERE attributes @> '{"ram": "16GB"}';

-- JSONB 인덱스
CREATE INDEX idx_products_attributes ON products USING GIN (attributes);
```

선택 기준:
- **JSONB**: 대부분의 경우 사용 (인덱싱 가능, 조회 빠름)
- **JSON**: 단순 로그 저장 등 조회 거의 없는 경우

#### 배열 타입
```sql
CREATE TABLE array_examples (
  tags TEXT[],                     -- 문자열 배열
  scores INTEGER[],                -- 정수 배열

  -- 다차원 배열
  matrix INTEGER[][]
);

-- 배열 사용
INSERT INTO products (name, tags)
VALUES ('Laptop', ARRAY['electronics', 'computers', 'dell']);

-- 배열 조회
SELECT * FROM products
WHERE 'electronics' = ANY(tags);

-- 배열 인덱스
CREATE INDEX idx_products_tags ON products USING GIN (tags);
```

주의: 정규화 관점에서는 별도 테이블이 더 나음

### 5. OS 관점: 타입 크기와 메모리 정렬

#### 메모리 정렬 (Alignment)
```sql
-- 비효율적인 컬럼 순서
CREATE TABLE alignment_bad (
  id BIGINT,          -- 8 bytes, offset 0
  flag1 BOOLEAN,      -- 1 byte,  offset 8
  -- padding 7 bytes (9~15)
  amount BIGINT,      -- 8 bytes, offset 16
  flag2 BOOLEAN,      -- 1 byte,  offset 24
  -- padding 7 bytes (25~31)
  count INTEGER       -- 4 bytes, offset 32
  -- padding 4 bytes (36~39)
);
-- 총 크기: 40 bytes (데이터 22 bytes + 패딩 18 bytes)

-- 효율적인 컬럼 순서 (크기 순 정렬)
CREATE TABLE alignment_good (
  id BIGINT,          -- 8 bytes, offset 0
  amount BIGINT,      -- 8 bytes, offset 8
  count INTEGER,      -- 4 bytes, offset 16
  flag1 BOOLEAN,      -- 1 byte,  offset 20
  flag2 BOOLEAN       -- 1 byte,  offset 21
  -- padding 2 bytes (22~23)
);
-- 총 크기: 24 bytes (데이터 22 bytes + 패딩 2 bytes)

-- 크기 확인
SELECT
  pg_column_size(ROW(1::BIGINT, TRUE, 100::BIGINT, FALSE, 10::INTEGER)) AS bad_size,
  pg_column_size(ROW(1::BIGINT, 100::BIGINT, 10::INTEGER, TRUE, FALSE)) AS good_size;
```

컬럼 순서 가이드:
1. **BIGINT, DOUBLE PRECISION** (8 bytes)
2. **INTEGER, REAL** (4 bytes)
3. **SMALLINT** (2 bytes)
4. **BOOLEAN, CHAR(1)** (1 byte)
5. **가변 길이 타입** (VARCHAR, TEXT, JSONB) - 마지막

#### 실제 테이블 크기 비교
```sql
-- 100만 행 삽입 테스트
INSERT INTO alignment_bad
SELECT
  generate_series(1, 1000000),
  (random() > 0.5),
  (random() * 1000000)::BIGINT,
  (random() > 0.5),
  (random() * 10000)::INTEGER;

INSERT INTO alignment_good
SELECT
  generate_series(1, 1000000),
  (random() * 1000000)::BIGINT,
  (random() * 10000)::INTEGER,
  (random() > 0.5),
  (random() > 0.5);

-- 크기 비교
SELECT
  pg_size_pretty(pg_relation_size('alignment_bad')) AS bad_size,
  pg_size_pretty(pg_relation_size('alignment_good')) AS good_size;

-- 결과:
-- bad_size: 54 MB
-- good_size: 42 MB (약 22% 절약)
```

영향:
- 디스크 사용량 감소
- 캐시 효율 증가 (같은 메모리에 더 많은 행)
- I/O 감소

### 6. 제약조건 (Constraints)

#### PRIMARY KEY
```sql
CREATE TABLE users (
  user_id SERIAL PRIMARY KEY,  -- NOT NULL + UNIQUE + Index
  email VARCHAR(255) NOT NULL UNIQUE
);

-- 복합 기본키
CREATE TABLE order_items (
  order_id INT,
  product_id INT,
  quantity INT,
  PRIMARY KEY (order_id, product_id)
);
```

#### FOREIGN KEY
```sql
CREATE TABLE orders (
  order_id SERIAL PRIMARY KEY,
  user_id INT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(user_id)
    ON DELETE CASCADE           -- 사용자 삭제 시 주문도 삭제
    ON UPDATE CASCADE           -- 사용자 ID 변경 시 주문도 변경
);

-- 다른 옵션
-- ON DELETE SET NULL: FK를 NULL로
-- ON DELETE SET DEFAULT: FK를 기본값으로
-- ON DELETE RESTRICT: 삭제 불가 (기본값)
```

#### CHECK 제약조건
```sql
CREATE TABLE products (
  product_id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  price NUMERIC(10, 2) NOT NULL,
  stock_quantity INT NOT NULL,

  -- 단순 CHECK
  CHECK (price > 0),
  CHECK (stock_quantity >= 0),

  -- 복합 CHECK
  CHECK (price < 1000000 OR stock_quantity < 100),

  -- 이름있는 CHECK
  CONSTRAINT chk_price_range CHECK (price BETWEEN 0.01 AND 999999.99)
);

-- 테이블 레벨 CHECK
ALTER TABLE orders
ADD CONSTRAINT chk_total_positive
CHECK (total_amount > 0);

-- CHECK 제약조건 위반 테스트
INSERT INTO products (name, price, stock_quantity)
VALUES ('Test', -10, 100);  -- ERROR: violates check constraint
```

#### UNIQUE 제약조건
```sql
CREATE TABLE users (
  user_id SERIAL PRIMARY KEY,
  username VARCHAR(100) NOT NULL,
  email VARCHAR(255) NOT NULL,
  phone VARCHAR(20),

  -- 단일 컬럼 UNIQUE
  UNIQUE (username),
  UNIQUE (email),

  -- 복합 UNIQUE
  CONSTRAINT uq_phone_verified UNIQUE (phone, email)
);

-- 부분 UNIQUE (조건부 유일성)
CREATE UNIQUE INDEX uq_active_username
ON users (username)
WHERE is_active = TRUE;
-- 활성 사용자 중에서만 username 중복 방지
```

#### EXCLUDE 제약조건 (PostgreSQL 특화)
```sql
-- 시간 겹침 방지
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE room_reservations (
  reservation_id SERIAL PRIMARY KEY,
  room_id INT,
  reserved_period TSRANGE,

  -- 같은 방에 시간 겹침 방지
  EXCLUDE USING GIST (
    room_id WITH =,
    reserved_period WITH &&
  )
);

-- 테스트
INSERT INTO room_reservations (room_id, reserved_period)
VALUES (101, '[2024-01-15 14:00, 2024-01-15 16:00)');

-- 겹치는 예약 시도 (실패)
INSERT INTO room_reservations (room_id, reserved_period)
VALUES (101, '[2024-01-15 15:00, 2024-01-15 17:00)');
-- ERROR: conflicting key value violates exclusion constraint

-- 다른 방은 가능
INSERT INTO room_reservations (room_id, reserved_period)
VALUES (102, '[2024-01-15 15:00, 2024-01-15 17:00)');
```

이커머스 예시:
```sql
-- 쿠폰 사용 기간 겹침 방지
CREATE TABLE coupon_campaigns (
  campaign_id SERIAL PRIMARY KEY,
  coupon_code VARCHAR(50),
  valid_period TSRANGE,

  EXCLUDE USING GIST (
    coupon_code WITH =,
    valid_period WITH &&
  )
);
```

### 7. 관계 패턴

#### 1:N 관계 (One-to-Many)
```sql
-- 가장 일반적인 패턴
CREATE TABLE users (
  user_id SERIAL PRIMARY KEY,
  username VARCHAR(100)
);

CREATE TABLE orders (
  order_id SERIAL PRIMARY KEY,
  user_id INT NOT NULL REFERENCES users(user_id),
  total_amount DECIMAL(10,2)
);

-- 한 사용자가 여러 주문 가능
-- 한 주문은 한 사용자만
```

#### N:M 관계 (Many-to-Many)
```sql
-- 중간 테이블 (Junction Table) 사용
CREATE TABLE products (
  product_id SERIAL PRIMARY KEY,
  name VARCHAR(255)
);

CREATE TABLE categories (
  category_id SERIAL PRIMARY KEY,
  name VARCHAR(100)
);

-- 다대다 관계 연결
CREATE TABLE product_categories (
  product_id INT REFERENCES products(product_id),
  category_id INT REFERENCES categories(category_id),
  PRIMARY KEY (product_id, category_id)
);

-- 한 상품이 여러 카테고리에 속할 수 있음
-- 한 카테고리에 여러 상품이 속할 수 있음
```

#### 자기참조 관계 (Self-Referencing)
```sql
-- 카테고리 계층 구조
CREATE TABLE categories (
  category_id SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  parent_category_id INT REFERENCES categories(category_id),
  level INT NOT NULL DEFAULT 0
);

-- 데이터 예시
INSERT INTO categories (category_id, name, parent_category_id, level) VALUES
(1, 'Electronics', NULL, 0),
(2, 'Computers', 1, 1),
(3, 'Laptops', 2, 2),
(4, 'Gaming Laptops', 3, 3);

-- 계층 조회 (Recursive CTE)
WITH RECURSIVE category_tree AS (
  -- Anchor: 최상위 카테고리
  SELECT category_id, name, parent_category_id, level, name::TEXT AS path
  FROM categories
  WHERE parent_category_id IS NULL

  UNION ALL

  -- Recursive: 하위 카테고리
  SELECT c.category_id, c.name, c.parent_category_id, c.level,
         ct.path || ' > ' || c.name
  FROM categories c
  JOIN category_tree ct ON c.parent_category_id = ct.category_id
)
SELECT * FROM category_tree ORDER BY path;
```

#### 폴리모픽 관계 (Polymorphic Association)
```sql
-- ❌ 안티패턴: 타입 컬럼으로 여러 테이블 참조
CREATE TABLE comments (
  comment_id SERIAL PRIMARY KEY,
  commentable_type VARCHAR(50),  -- 'Product' or 'Review'
  commentable_id INT,            -- product_id or review_id
  content TEXT
);

-- 문제: FK 제약조건 불가, 참조 무결성 보장 어려움

-- ✅ 해결책 1: 별도 테이블
CREATE TABLE product_comments (
  comment_id SERIAL PRIMARY KEY,
  product_id INT REFERENCES products(product_id),
  content TEXT
);

CREATE TABLE review_comments (
  comment_id SERIAL PRIMARY KEY,
  review_id INT REFERENCES reviews(review_id),
  content TEXT
);

-- ✅ 해결책 2: 슈퍼타입/서브타입 (상속)
CREATE TABLE comments (
  comment_id SERIAL PRIMARY KEY,
  content TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE product_comments (
  product_id INT REFERENCES products(product_id)
) INHERITS (comments);

CREATE TABLE review_comments (
  review_id INT REFERENCES reviews(review_id)
) INHERITS (comments);

-- 모든 댓글 조회
SELECT * FROM comments;  -- 자식 테이블 포함

-- 특정 타입만
SELECT * FROM ONLY comments;  -- 부모 테이블만
SELECT * FROM product_comments;  -- 상품 댓글만
```

### 8. 시계열 데이터 모델링

#### 이벤트 로그 테이블 (파티셔닝)
```sql
-- 파티셔닝된 이벤트 로그
CREATE TABLE event_logs (
  event_id BIGSERIAL,
  user_id INT,
  event_type VARCHAR(50),
  event_data JSONB,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (event_id, created_at)
) PARTITION BY RANGE (created_at);

-- 월별 파티션 생성
CREATE TABLE event_logs_2024_01 PARTITION OF event_logs
FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE event_logs_2024_02 PARTITION OF event_logs
FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

-- 인덱스는 파티션별로 자동 생성
CREATE INDEX idx_event_logs_user_id ON event_logs(user_id);
CREATE INDEX idx_event_logs_type ON event_logs(event_type);
CREATE INDEX idx_event_logs_data ON event_logs USING GIN (event_data);

-- 조회 시 파티션 프루닝
EXPLAIN SELECT * FROM event_logs
WHERE created_at >= '2024-01-15' AND created_at < '2024-01-20';
-- 2024_01 파티션만 스캔
```

#### 이벤트 소싱 패턴
```sql
-- 이벤트 저장소
CREATE TABLE order_events (
  event_id BIGSERIAL PRIMARY KEY,
  order_id UUID NOT NULL,
  event_type VARCHAR(50) NOT NULL,
  event_data JSONB NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  created_by INT
);

-- 이벤트 타입 예시
INSERT INTO order_events (order_id, event_type, event_data) VALUES
('550e8400-e29b-41d4-a716-446655440000', 'OrderCreated', '{"user_id": 1, "total": 100}'),
('550e8400-e29b-41d4-a716-446655440000', 'PaymentReceived', '{"amount": 100, "method": "card"}'),
('550e8400-e29b-41d4-a716-446655440000', 'OrderShipped', '{"tracking_number": "1234"}');

-- 현재 상태 재구성 (Projection)
CREATE MATERIALIZED VIEW current_order_status AS
SELECT
  order_id,
  (event_data->>'user_id')::INT AS user_id,
  CASE
    WHEN latest_event = 'OrderCancelled' THEN 'cancelled'
    WHEN latest_event = 'OrderDelivered' THEN 'delivered'
    WHEN latest_event = 'OrderShipped' THEN 'shipped'
    WHEN latest_event = 'PaymentReceived' THEN 'paid'
    ELSE 'pending'
  END AS status,
  last_updated
FROM (
  SELECT DISTINCT ON (order_id)
    order_id,
    event_type AS latest_event,
    created_at AS last_updated,
    event_data
  FROM order_events
  ORDER BY order_id, created_at DESC
) latest_events;

-- 인덱스
CREATE INDEX idx_current_order_status_user ON current_order_status(user_id);

-- 정기적으로 갱신
REFRESH MATERIALIZED VIEW CONCURRENTLY current_order_status;
```

## 실습 SQL

### 실습 1: 비정규화 → 3NF 변환

#### Step 1: 비정규화 테이블 생성
```sql
-- 0NF 테이블
CREATE TABLE sales_denormalized (
  sale_id SERIAL PRIMARY KEY,
  sale_date DATE,
  customer_name VARCHAR(100),
  customer_email VARCHAR(255),
  customer_phone VARCHAR(20),
  product_name VARCHAR(255),
  product_category VARCHAR(100),
  product_price DECIMAL(10,2),
  quantity INT,
  total_amount DECIMAL(10,2)
);

-- 샘플 데이터
INSERT INTO sales_denormalized VALUES
(1, '2024-01-15', 'John Doe', 'john@example.com', '010-1234-5678',
 'Laptop', 'Electronics', 1200.00, 1, 1200.00),
(2, '2024-01-16', 'John Doe', 'john@example.com', '010-1234-5678',
 'Mouse', 'Accessories', 25.00, 2, 50.00),
(3, '2024-01-16', 'Jane Smith', 'jane@example.com', '010-9876-5432',
 'Laptop', 'Electronics', 1200.00, 1, 1200.00);
```

#### Step 2: 1NF 변환
```sql
-- 이미 1NF (원자값만 사용)
-- 배열이나 중복 그룹이 없음
```

#### Step 3: 2NF 변환 (부분 종속 제거)
```sql
-- 고객 테이블 추출
CREATE TABLE customers_2nf (
  customer_id SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  email VARCHAR(255) UNIQUE NOT NULL,
  phone VARCHAR(20)
);

INSERT INTO customers_2nf (name, email, phone)
SELECT DISTINCT customer_name, customer_email, customer_phone
FROM sales_denormalized;

-- 상품 테이블 추출
CREATE TABLE products_2nf (
  product_id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  category VARCHAR(100),
  price DECIMAL(10,2) NOT NULL CHECK (price > 0)
);

INSERT INTO products_2nf (name, category, price)
SELECT DISTINCT product_name, product_category, product_price
FROM sales_denormalized;

-- 판매 테이블 (FK만)
CREATE TABLE sales_2nf (
  sale_id SERIAL PRIMARY KEY,
  sale_date DATE NOT NULL,
  customer_id INT REFERENCES customers_2nf(customer_id),
  product_id INT REFERENCES products_2nf(product_id),
  quantity INT NOT NULL CHECK (quantity > 0),
  total_amount DECIMAL(10,2) NOT NULL
);

INSERT INTO sales_2nf (sale_date, customer_id, product_id, quantity, total_amount)
SELECT
  sd.sale_date,
  c.customer_id,
  p.product_id,
  sd.quantity,
  sd.total_amount
FROM sales_denormalized sd
JOIN customers_2nf c ON sd.customer_email = c.email
JOIN products_2nf p ON sd.product_name = p.name;
```

#### Step 4: 3NF 변환 (이행 종속 제거)
```sql
-- 카테고리 테이블 추출
CREATE TABLE categories_3nf (
  category_id SERIAL PRIMARY KEY,
  name VARCHAR(100) UNIQUE NOT NULL
);

INSERT INTO categories_3nf (name)
SELECT DISTINCT category FROM products_2nf;

-- 상품 테이블 수정
CREATE TABLE products_3nf (
  product_id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  category_id INT REFERENCES categories_3nf(category_id),
  price DECIMAL(10,2) NOT NULL CHECK (price > 0)
);

INSERT INTO products_3nf (name, category_id, price)
SELECT p.name, c.category_id, p.price
FROM products_2nf p
JOIN categories_3nf c ON p.category = c.name;

-- 판매 테이블은 그대로
CREATE TABLE sales_3nf (
  sale_id SERIAL PRIMARY KEY,
  sale_date DATE NOT NULL,
  customer_id INT REFERENCES customers_2nf(customer_id),
  product_id INT REFERENCES products_3nf(product_id),
  quantity INT NOT NULL CHECK (quantity > 0),
  total_amount DECIMAL(10,2) NOT NULL
);

-- 조회 (JOIN 필요)
SELECT
  s.sale_id,
  s.sale_date,
  c.name AS customer_name,
  c.email,
  p.name AS product_name,
  cat.name AS category,
  s.quantity,
  s.total_amount
FROM sales_3nf s
JOIN customers_2nf c ON s.customer_id = c.customer_id
JOIN products_3nf p ON s.product_id = p.product_id
JOIN categories_3nf cat ON p.category_id = cat.category_id;
```

### 실습 2: 이커머스 스키마 완성

```sql
-- 1. 사용자와 주소
CREATE TABLE users (
  user_id SERIAL PRIMARY KEY,
  username VARCHAR(100) NOT NULL UNIQUE,
  email VARCHAR(255) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  phone VARCHAR(20),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  CHECK (char_length(username) >= 3),
  CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}$')
);

CREATE TABLE addresses (
  address_id SERIAL PRIMARY KEY,
  user_id INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  address_line1 VARCHAR(255) NOT NULL,
  address_line2 VARCHAR(255),
  city VARCHAR(100) NOT NULL,
  state VARCHAR(100),
  zipcode VARCHAR(10) NOT NULL,
  country VARCHAR(2) NOT NULL DEFAULT 'KR',
  is_default BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_addresses_user_id ON addresses(user_id);
CREATE INDEX idx_addresses_default ON addresses(user_id) WHERE is_default = TRUE;

-- 2. 카테고리 (계층 구조)
CREATE TABLE categories (
  category_id SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  parent_category_id INT REFERENCES categories(category_id),
  level INT NOT NULL DEFAULT 0,
  display_order INT DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  CHECK (level >= 0 AND level <= 5)
);

CREATE INDEX idx_categories_parent ON categories(parent_category_id);

-- 3. 상품과 변형
CREATE TABLE products (
  product_id SERIAL PRIMARY KEY,
  category_id INT REFERENCES categories(category_id),
  name VARCHAR(255) NOT NULL,
  description TEXT,
  base_price DECIMAL(10,2) NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  CHECK (base_price >= 0)
);

CREATE TABLE product_variants (
  variant_id SERIAL PRIMARY KEY,
  product_id INT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
  sku VARCHAR(100) UNIQUE NOT NULL,
  name VARCHAR(255),
  price DECIMAL(10,2) NOT NULL,
  attributes JSONB,  -- {"color": "Red", "size": "L"}
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  CHECK (price >= 0)
);

CREATE INDEX idx_product_variants_product ON product_variants(product_id);
CREATE INDEX idx_product_variants_sku ON product_variants(sku);
CREATE INDEX idx_product_variants_attrs ON product_variants USING GIN (attributes);

-- 4. 재고
CREATE TABLE inventory (
  inventory_id SERIAL PRIMARY KEY,
  variant_id INT NOT NULL REFERENCES product_variants(variant_id),
  quantity INT NOT NULL DEFAULT 0,
  reserved_quantity INT NOT NULL DEFAULT 0,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  CHECK (quantity >= 0),
  CHECK (reserved_quantity >= 0),
  CHECK (reserved_quantity <= quantity),

  UNIQUE (variant_id)
);

-- 5. 장바구니
CREATE TABLE carts (
  cart_id SERIAL PRIMARY KEY,
  user_id INT REFERENCES users(user_id) ON DELETE CASCADE,
  session_id VARCHAR(255),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  CHECK ((user_id IS NOT NULL) OR (session_id IS NOT NULL))
);

CREATE TABLE cart_items (
  cart_item_id SERIAL PRIMARY KEY,
  cart_id INT NOT NULL REFERENCES carts(cart_id) ON DELETE CASCADE,
  variant_id INT NOT NULL REFERENCES product_variants(variant_id),
  quantity INT NOT NULL CHECK (quantity > 0),
  added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  UNIQUE (cart_id, variant_id)
);

-- 6. 주문
CREATE TABLE orders (
  order_id BIGSERIAL PRIMARY KEY,
  user_id INT NOT NULL REFERENCES users(user_id),
  shipping_address_id INT REFERENCES addresses(address_id),
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  total_amount DECIMAL(10,2) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  CHECK (status IN ('pending', 'paid', 'processing', 'shipped', 'delivered', 'cancelled', 'refunded')),
  CHECK (total_amount >= 0)
);

CREATE TABLE order_items (
  order_item_id BIGSERIAL PRIMARY KEY,
  order_id BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
  variant_id INT NOT NULL REFERENCES product_variants(variant_id),
  quantity INT NOT NULL CHECK (quantity > 0),
  price DECIMAL(10,2) NOT NULL CHECK (price >= 0),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_orders_user_id ON orders(user_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_created_at ON orders(created_at);
CREATE INDEX idx_order_items_order_id ON order_items(order_id);

-- 7. 결제
CREATE TABLE payments (
  payment_id BIGSERIAL PRIMARY KEY,
  order_id BIGINT NOT NULL REFERENCES orders(order_id),
  payment_method VARCHAR(50) NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  transaction_id VARCHAR(255) UNIQUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  CHECK (payment_method IN ('card', 'bank_transfer', 'paypal', 'cash')),
  CHECK (status IN ('pending', 'completed', 'failed', 'refunded')),
  CHECK (amount > 0)
);

CREATE INDEX idx_payments_order_id ON payments(order_id);
CREATE INDEX idx_payments_status ON payments(status);

-- 8. 배송
CREATE TABLE shipments (
  shipment_id BIGSERIAL PRIMARY KEY,
  order_id BIGINT NOT NULL REFERENCES orders(order_id),
  carrier VARCHAR(100),
  tracking_number VARCHAR(255) UNIQUE,
  status VARCHAR(20) NOT NULL DEFAULT 'preparing',
  shipped_at TIMESTAMP,
  delivered_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  CHECK (status IN ('preparing', 'shipped', 'in_transit', 'delivered', 'returned')),
  CHECK (delivered_at IS NULL OR shipped_at IS NOT NULL)
);

CREATE INDEX idx_shipments_order_id ON shipments(order_id);
CREATE INDEX idx_shipments_tracking ON shipments(tracking_number);

-- 9. 쿠폰
CREATE TABLE coupons (
  coupon_id SERIAL PRIMARY KEY,
  code VARCHAR(50) UNIQUE NOT NULL,
  discount_type VARCHAR(20) NOT NULL,
  discount_value DECIMAL(10,2) NOT NULL,
  min_order_amount DECIMAL(10,2),
  max_discount_amount DECIMAL(10,2),
  valid_from TIMESTAMP NOT NULL,
  valid_until TIMESTAMP NOT NULL,
  usage_limit INT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  CHECK (discount_type IN ('percentage', 'fixed_amount')),
  CHECK (discount_value > 0),
  CHECK (valid_until > valid_from)
);

CREATE TABLE coupon_usages (
  usage_id BIGSERIAL PRIMARY KEY,
  coupon_id INT NOT NULL REFERENCES coupons(coupon_id),
  user_id INT NOT NULL REFERENCES users(user_id),
  order_id BIGINT NOT NULL REFERENCES orders(order_id),
  discount_amount DECIMAL(10,2) NOT NULL,
  used_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  UNIQUE (coupon_id, order_id)
);

-- 10. 리뷰
CREATE TABLE reviews (
  review_id BIGSERIAL PRIMARY KEY,
  product_id INT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
  user_id INT NOT NULL REFERENCES users(user_id),
  order_id BIGINT REFERENCES orders(order_id),
  rating INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  title VARCHAR(255),
  content TEXT,
  is_verified_purchase BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  UNIQUE (product_id, user_id, order_id)
);

CREATE TABLE review_images (
  image_id BIGSERIAL PRIMARY KEY,
  review_id BIGINT NOT NULL REFERENCES reviews(review_id) ON DELETE CASCADE,
  image_url VARCHAR(500) NOT NULL,
  display_order INT DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_reviews_product_id ON reviews(product_id);
CREATE INDEX idx_reviews_user_id ON reviews(user_id);
CREATE INDEX idx_review_images_review_id ON review_images(review_id);

-- 11. 이벤트 로그 (파티셔닝)
CREATE TABLE event_logs (
  event_id BIGSERIAL,
  user_id INT,
  event_type VARCHAR(50) NOT NULL,
  event_data JSONB,
  ip_address INET,
  user_agent TEXT,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (event_id, created_at)
) PARTITION BY RANGE (created_at);

-- 월별 파티션
CREATE TABLE event_logs_2024_01 PARTITION OF event_logs
FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE event_logs_2024_02 PARTITION OF event_logs
FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

CREATE INDEX idx_event_logs_user_id ON event_logs(user_id);
CREATE INDEX idx_event_logs_type ON event_logs(event_type);
CREATE INDEX idx_event_logs_data ON event_logs USING GIN (event_data);
```

### 실습 3: Materialized View로 반정규화

```sql
-- 상품 통계 Materialized View
CREATE MATERIALIZED VIEW mv_product_statistics AS
SELECT
  p.product_id,
  p.name AS product_name,
  c.name AS category_name,
  COUNT(DISTINCT oi.order_id) AS total_orders,
  SUM(oi.quantity) AS total_quantity_sold,
  SUM(oi.quantity * oi.price) AS total_revenue,
  AVG(oi.price) AS avg_sale_price,
  COUNT(DISTINCT r.review_id) AS review_count,
  COALESCE(AVG(r.rating), 0) AS avg_rating,
  MAX(oi.created_at) AS last_sold_at
FROM products p
LEFT JOIN categories c ON p.category_id = c.category_id
LEFT JOIN product_variants pv ON p.product_id = pv.product_id
LEFT JOIN order_items oi ON pv.variant_id = oi.variant_id
LEFT JOIN orders o ON oi.order_id = o.order_id AND o.status = 'completed'
LEFT JOIN reviews r ON p.product_id = r.product_id
GROUP BY p.product_id, p.name, c.name;

-- 인덱스
CREATE INDEX idx_mv_product_stats_category ON mv_product_statistics(category_name);
CREATE INDEX idx_mv_product_stats_revenue ON mv_product_statistics(total_revenue DESC);
CREATE INDEX idx_mv_product_stats_rating ON mv_product_statistics(avg_rating DESC);

-- 갱신
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_product_statistics;

-- 빠른 조회
SELECT * FROM mv_product_statistics
WHERE category_name = 'Electronics'
ORDER BY total_revenue DESC
LIMIT 10;
```

## 직접 확인해보기

### 1. 컬럼 순서에 따른 크기 변화
```sql
-- 테스트 테이블 생성
CREATE TABLE test_alignment_bad (
  c1 BIGINT,
  c2 BOOLEAN,
  c3 BIGINT,
  c4 BOOLEAN,
  c5 INTEGER
);

CREATE TABLE test_alignment_good (
  c1 BIGINT,
  c3 BIGINT,
  c5 INTEGER,
  c2 BOOLEAN,
  c4 BOOLEAN
);

-- 100만 행 삽입
INSERT INTO test_alignment_bad
SELECT i, (i % 2)::BOOLEAN, i * 2, (i % 3 = 0)::BOOLEAN, i::INTEGER
FROM generate_series(1, 1000000) i;

INSERT INTO test_alignment_good
SELECT i, i * 2, i::INTEGER, (i % 2)::BOOLEAN, (i % 3 = 0)::BOOLEAN
FROM generate_series(1, 1000000) i;

-- 크기 비교
SELECT
  pg_size_pretty(pg_relation_size('test_alignment_bad')) AS bad_size,
  pg_size_pretty(pg_relation_size('test_alignment_good')) AS good_size,
  pg_size_pretty(pg_relation_size('test_alignment_bad') - pg_relation_size('test_alignment_good')) AS diff;
```

### 2. 제약조건 성능 테스트
```sql
-- CHECK 제약조건 vs 애플리케이션 검증
CREATE TABLE products_with_check (
  product_id SERIAL PRIMARY KEY,
  price DECIMAL(10,2) CHECK (price > 0)
);

CREATE TABLE products_no_check (
  product_id SERIAL PRIMARY KEY,
  price DECIMAL(10,2)
);

-- 삽입 성능 비교
\timing on
INSERT INTO products_with_check (price)
SELECT random() * 1000 + 1 FROM generate_series(1, 100000);

INSERT INTO products_no_check (price)
SELECT random() * 1000 + 1 FROM generate_series(1, 100000);
\timing off

-- 무결성 위반 테스트
INSERT INTO products_with_check (price) VALUES (-10);  -- ERROR
INSERT INTO products_no_check (price) VALUES (-10);     -- OK (문제)
```

### 3. 정규화 vs 반정규화 쿼리 성능
```sql
-- 정규화된 조회 (3-way JOIN)
EXPLAIN ANALYZE
SELECT o.order_id, u.username, u.email, o.total_amount
FROM orders o
JOIN users u ON o.user_id = u.user_id
JOIN addresses a ON o.shipping_address_id = a.address_id
LIMIT 1000;

-- 반정규화된 조회 (username 중복 저장)
ALTER TABLE orders ADD COLUMN username_cache VARCHAR(100);
UPDATE orders o SET username_cache = u.username
FROM users u WHERE o.user_id = u.user_id;

EXPLAIN ANALYZE
SELECT order_id, username_cache, total_amount
FROM orders
LIMIT 1000;
```

## 실무 팁

### 1. 스키마 설계 체크리스트
- [ ] 정규화 수준 결정 (보통 3NF)
- [ ] 기본키 선택 (SERIAL vs UUID vs Natural Key)
- [ ] 외래키 ON DELETE/UPDATE 동작 정의
- [ ] 필수/선택 컬럼 명확히 (NOT NULL)
- [ ] CHECK 제약조건으로 비즈니스 룰 강제
- [ ] 인덱스 전략 (FK, 검색 컬럼, UNIQUE)
- [ ] 파티셔닝 필요성 검토 (시계열, 대용량)
- [ ] 감사 로그 (created_at, updated_at)

### 2. 마이그레이션 전략
```sql
-- NOT NULL 추가 시
-- ❌ 바로 추가하면 대용량 테이블은 오래 걸림
ALTER TABLE users ADD COLUMN phone VARCHAR(20) NOT NULL;

-- ✅ 단계적 추가
ALTER TABLE users ADD COLUMN phone VARCHAR(20);
UPDATE users SET phone = '' WHERE phone IS NULL;
ALTER TABLE users ALTER COLUMN phone SET NOT NULL;

-- 또는 기본값 사용 (PostgreSQL 11+)
ALTER TABLE users ADD COLUMN phone VARCHAR(20) NOT NULL DEFAULT '';
ALTER TABLE users ALTER COLUMN phone DROP DEFAULT;
```

### 3. 타입 변경 주의
```sql
-- ❌ 테이블 락 발생
ALTER TABLE orders ALTER COLUMN order_id TYPE BIGINT;

-- ✅ 새 컬럼 추가 → 마이그레이션 → 교체
ALTER TABLE orders ADD COLUMN order_id_new BIGINT;
UPDATE orders SET order_id_new = order_id;
-- 애플리케이션 배포 (양쪽 컬럼 사용)
ALTER TABLE orders DROP COLUMN order_id;
ALTER TABLE orders RENAME COLUMN order_id_new TO order_id;
```

### 4. 소프트 삭제 패턴
```sql
-- 물리적 삭제 대신 소프트 삭제
ALTER TABLE users ADD COLUMN deleted_at TIMESTAMP;
CREATE INDEX idx_users_active ON users(user_id) WHERE deleted_at IS NULL;

-- 삭제
UPDATE users SET deleted_at = CURRENT_TIMESTAMP WHERE user_id = 123;

-- 조회 (활성 사용자만)
SELECT * FROM users WHERE deleted_at IS NULL;

-- 또는 뷰로 추상화
CREATE VIEW active_users AS
SELECT * FROM users WHERE deleted_at IS NULL;
```

### 5. UUID vs SERIAL
```sql
-- SERIAL: 순차 증가
CREATE TABLE orders_serial (
  order_id SERIAL PRIMARY KEY
);
-- 장점: 작음 (4 bytes), 빠름, 순서 보장
-- 단점: 분산 환경 어려움, ID 예측 가능

-- UUID: 전역 고유
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE TABLE orders_uuid (
  order_id UUID PRIMARY KEY DEFAULT uuid_generate_v4()
);
-- 장점: 분산 환경, 병합 쉬움, 보안
-- 단점: 큼 (16 bytes), 인덱스 비효율 (랜덤 삽입)

-- PostgreSQL 17: UUIDv7 지원 (시간 기반 정렬)
-- 아직 내장 함수 없음, 확장 필요
```

### 6. JSONB 활용 시점
```sql
-- ✅ JSONB가 적합한 경우
-- - 스키마가 유동적
-- - 드문 조회
-- - 비정형 메타데이터
CREATE TABLE products (
  product_id SERIAL PRIMARY KEY,
  name VARCHAR(255),
  attributes JSONB  -- {"brand": "Dell", "warranty": "2 years"}
);

-- ❌ JSONB 부적합
-- - 자주 조회/필터링
-- - 관계가 명확
-- - 무결성 중요
-- → 별도 테이블로 정규화
```

### 7. 제약조건 네이밍 컨벤션
```sql
-- 명확한 이름으로 에러 메시지 개선
CREATE TABLE orders (
  order_id SERIAL,
  user_id INT,
  total_amount DECIMAL(10,2),

  CONSTRAINT pk_orders PRIMARY KEY (order_id),
  CONSTRAINT fk_orders_users FOREIGN KEY (user_id) REFERENCES users(user_id),
  CONSTRAINT chk_orders_amount_positive CHECK (total_amount > 0),
  CONSTRAINT uq_orders_tracking_number UNIQUE (tracking_number)
);

-- 에러 예시
-- ERROR: duplicate key value violates unique constraint "uq_orders_tracking_number"
-- 제약조건 이름으로 문제 즉시 파악
```

## 참고 링크

### 공식 문서
- [PostgreSQL 17 Documentation - Data Definition](https://www.postgresql.org/docs/17/ddl.html)
- [Chapter 5. Data Definition](https://www.postgresql.org/docs/17/ddl.html)
- [Chapter 8. Data Types](https://www.postgresql.org/docs/17/datatype.html)
- [Constraints](https://www.postgresql.org/docs/17/ddl-constraints.html)
- [Table Partitioning](https://www.postgresql.org/docs/17/ddl-partitioning.html)

### 정규화 이론
- Database Design and Normalization (academic)
- Codd's Normal Forms
- Boyce-Codd Normal Form (BCNF)

### PostgreSQL 17 신기능
- [JSON Functions (JSON_TABLE, etc.)](https://www.postgresql.org/docs/17/functions-json.html)
- [Improved Partitioning](https://www.postgresql.org/docs/17/release-17.html)
- [Performance Improvements](https://www.postgresql.org/about/news/postgresql-17-released-2911/)

### 모범 사례
- [PostgreSQL Data Types Best Practices](https://wiki.postgresql.org/wiki/Don%27t_Do_This)
- Schema Design Patterns
- Event Sourcing with PostgreSQL

### 도구
- ERD 도구: dbdiagram.io, draw.io, DataGrip
- 마이그레이션: Flyway, Liquibase
- ORM: SQLAlchemy, TypeORM, Prisma

### 관련 노트
- `03-indexing.md`: 인덱스 전략
- `04-partitioning.md`: 파티셔닝 심화
- `09-advanced-sql.md`: 고급 SQL 패턴

---

**다음 노트**: `09-advanced-sql.md` - 고급 SQL
**이전 노트**: `07-query-optimization.md` - 쿼리 최적화와 EXPLAIN
