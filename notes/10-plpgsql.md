# PL/pgSQL과 서버 프로그래밍

## 한줄 요약
PL/pgSQL은 PostgreSQL의 내장 절차형 언어로, 복잡한 비즈니스 로직을 데이터베이스 서버에서 직접 실행하여 네트워크 왕복을 줄이고 데이터 무결성을 보장하는 강력한 도구입니다.

## 왜 알아야 하는가

### 1. 성능 최적화
- **네트워크 왕복 감소**: 여러 SQL 문을 하나의 함수로 묶어 실행
- **서버 측 처리**: 데이터를 애플리케이션으로 가져오지 않고 DB에서 직접 처리
- **트랜잭션 제어**: 프로시저를 통한 세밀한 트랜잭션 관리

### 2. 데이터 무결성
- **트리거**: 데이터 변경 시 자동으로 비즈니스 규칙 적용
- **제약조건 강화**: 복잡한 검증 로직을 DB 레벨에서 보장
- **감사 추적**: 모든 변경사항 자동 기록

### 3. 비즈니스 로직 중앙화
- **일관성**: 모든 애플리케이션이 동일한 로직 사용
- **유지보수**: 로직 변경 시 한 곳만 수정
- **재사용성**: 여러 애플리케이션에서 동일 함수 호출

### 4. 보안
- **권한 제어**: 함수 실행 권한만 부여하고 테이블 직접 접근 차단
- **SQL 인젝션 방지**: 파라미터화된 쿼리 자동 처리
- **민감 데이터 보호**: 복잡한 접근 로직을 함수 내부에 캡슐화

## 핵심 개념

### 1. 함수 (Function) vs 프로시저 (Procedure)

#### 함수 (FUNCTION)
```sql
CREATE OR REPLACE FUNCTION calculate_order_total(order_id_param INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    total_amount NUMERIC := 0;
BEGIN
    SELECT COALESCE(SUM(oi.quantity * oi.price), 0)
    INTO total_amount
    FROM order_items oi
    WHERE oi.order_id = order_id_param;

    RETURN total_amount;
END;
$$;

-- 사용법
SELECT calculate_order_total(1001);
```

**함수의 특징**:
- 반드시 값을 반환 (RETURNS 절 필수)
- SELECT 문에서 사용 가능
- 트랜잭션 제어 불가 (COMMIT/ROLLBACK 불가)
- 단일 트랜잭션 내에서 실행

#### 프로시저 (PROCEDURE) - PostgreSQL 11+
```sql
CREATE OR REPLACE PROCEDURE process_monthly_orders(target_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    order_rec RECORD;
    processed_count INTEGER := 0;
BEGIN
    FOR order_rec IN
        SELECT order_id, total_amount
        FROM orders
        WHERE DATE_TRUNC('month', created_at) = DATE_TRUNC('month', target_month)
    LOOP
        -- 각 주문 처리
        UPDATE orders
        SET status = 'processed'
        WHERE order_id = order_rec.order_id;

        processed_count := processed_count + 1;

        -- 100개마다 COMMIT (프로시저만 가능!)
        IF processed_count % 100 = 0 THEN
            COMMIT;
            RAISE NOTICE '% orders processed', processed_count;
        END IF;
    END LOOP;

    COMMIT;
    RAISE NOTICE 'Total % orders processed', processed_count;
END;
$$;

-- 사용법
CALL process_monthly_orders('2024-01-01');
```

**프로시저의 특징**:
- 반환값 없음 (OUT 파라미터로 값 전달 가능)
- CALL 문으로 실행
- **트랜잭션 제어 가능** (COMMIT/ROLLBACK 사용 가능)
- 대량 데이터 처리에 적합

**주요 차이점 비교**:
| 특성 | FUNCTION | PROCEDURE |
|------|----------|-----------|
| 반환값 | 필수 (RETURNS) | 선택 (OUT 파라미터) |
| 실행 방법 | SELECT | CALL |
| 트랜잭션 제어 | 불가 | 가능 (COMMIT/ROLLBACK) |
| SELECT 문 사용 | 가능 | 불가 |
| 용도 | 계산, 조회, 변환 | 복잡한 처리, 배치 작업 |

### 2. 변수와 데이터 타입

```sql
CREATE OR REPLACE FUNCTION variable_examples()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    -- 기본 타입
    user_count INTEGER;
    user_name TEXT := 'Unknown';
    discount_rate NUMERIC(5,2) := 0.15;
    is_active BOOLEAN := TRUE;

    -- 테이블 컬럼 타입 참조
    user_email users.email%TYPE;

    -- 전체 행 타입
    user_row users%ROWTYPE;

    -- RECORD 타입 (동적 구조)
    dynamic_rec RECORD;

    -- 배열
    product_ids INTEGER[] := ARRAY[1, 2, 3];

    -- 상수
    TAX_RATE CONSTANT NUMERIC := 0.10;
BEGIN
    -- 변수 할당
    SELECT COUNT(*) INTO user_count FROM users;

    -- 행 전체 저장
    SELECT * INTO user_row FROM users WHERE user_id = 1;
    user_email := user_row.email;

    -- RECORD 사용 (동적 쿼리 결과)
    SELECT user_id, email INTO dynamic_rec FROM users WHERE user_id = 1;

    RETURN format('Users: %s, Email: %s', user_count, user_email);
END;
$$;
```

### 3. 제어문과 반복문

#### IF-THEN-ELSE
```sql
CREATE OR REPLACE FUNCTION get_discount_rate(customer_id_param INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    order_count INTEGER;
    total_spent NUMERIC;
    discount NUMERIC := 0;
BEGIN
    -- 고객의 주문 이력 조회
    SELECT COUNT(*), COALESCE(SUM(total_amount), 0)
    INTO order_count, total_spent
    FROM orders
    WHERE user_id = customer_id_param AND status = 'completed';

    -- 등급별 할인율 적용
    IF total_spent >= 1000000 THEN
        discount := 0.20;  -- VIP: 20%
    ELSIF total_spent >= 500000 THEN
        discount := 0.15;  -- Gold: 15%
    ELSIF total_spent >= 100000 THEN
        discount := 0.10;  -- Silver: 10%
    ELSIF order_count >= 5 THEN
        discount := 0.05;  -- Bronze: 5%
    ELSE
        discount := 0;     -- 일반: 0%
    END IF;

    RETURN discount;
END;
$$;
```

#### CASE 문
```sql
CREATE OR REPLACE FUNCTION get_order_status_label(order_id_param INTEGER)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    order_status TEXT;
    status_label TEXT;
BEGIN
    SELECT status INTO order_status
    FROM orders
    WHERE order_id = order_id_param;

    -- CASE 표현식
    status_label := CASE order_status
        WHEN 'pending' THEN '결제 대기'
        WHEN 'paid' THEN '결제 완료'
        WHEN 'shipping' THEN '배송 중'
        WHEN 'delivered' THEN '배송 완료'
        WHEN 'cancelled' THEN '주문 취소'
        ELSE '알 수 없음'
    END;

    RETURN status_label;
END;
$$;
```

#### LOOP / WHILE / FOR
```sql
CREATE OR REPLACE FUNCTION loop_examples()
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    counter INTEGER := 0;
    product_rec RECORD;
    i INTEGER;
BEGIN
    -- 기본 LOOP (무한 루프)
    LOOP
        counter := counter + 1;
        EXIT WHEN counter > 5;  -- 탈출 조건
        RAISE NOTICE 'Counter: %', counter;
    END LOOP;

    -- WHILE LOOP
    counter := 0;
    WHILE counter < 5 LOOP
        counter := counter + 1;
        RAISE NOTICE 'While counter: %', counter;
    END LOOP;

    -- FOR LOOP (정수 범위)
    FOR i IN 1..5 LOOP
        RAISE NOTICE 'For i: %', i;
    END LOOP;

    -- FOR LOOP (역순)
    FOR i IN REVERSE 5..1 LOOP
        RAISE NOTICE 'Reverse i: %', i;
    END LOOP;

    -- FOR LOOP (쿼리 결과 순회)
    FOR product_rec IN
        SELECT product_id, name, price
        FROM products
        WHERE price > 10000
        LIMIT 10
    LOOP
        RAISE NOTICE 'Product: % - %원', product_rec.name, product_rec.price;

        -- CONTINUE 사용
        CONTINUE WHEN product_rec.price < 50000;

        RAISE NOTICE 'High-value product!';
    END LOOP;
END;
$$;
```

### 4. 반환 타입

#### RETURNS TABLE
```sql
CREATE OR REPLACE FUNCTION get_top_products(limit_count INTEGER DEFAULT 10)
RETURNS TABLE(
    product_id INTEGER,
    product_name TEXT,
    category_name TEXT,
    total_sold BIGINT,
    revenue NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.product_id,
        p.name,
        c.name AS category_name,
        COUNT(oi.order_item_id) AS total_sold,
        SUM(oi.quantity * oi.price) AS revenue
    FROM products p
    JOIN categories c ON p.category_id = c.category_id
    JOIN order_items oi ON p.product_id = oi.product_id
    GROUP BY p.product_id, p.name, c.name
    ORDER BY revenue DESC
    LIMIT limit_count;
END;
$$;

-- 사용법
SELECT * FROM get_top_products(5);
```

#### RETURNS SETOF
```sql
CREATE OR REPLACE FUNCTION get_user_orders(user_id_param INTEGER)
RETURNS SETOF orders
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM orders
    WHERE user_id = user_id_param
    ORDER BY created_at DESC;
END;
$$;

-- 사용법
SELECT * FROM get_user_orders(123);
```

#### OUT 파라미터
```sql
CREATE OR REPLACE FUNCTION get_order_summary(
    order_id_param INTEGER,
    OUT item_count INTEGER,
    OUT total_amount NUMERIC,
    OUT discount_amount NUMERIC,
    OUT final_amount NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT
        COUNT(*),
        SUM(quantity * price),
        COALESCE(c.discount_amount, 0)
    INTO item_count, total_amount, discount_amount
    FROM order_items oi
    LEFT JOIN orders o ON oi.order_id = o.order_id
    LEFT JOIN coupons c ON o.coupon_id = c.coupon_id
    WHERE oi.order_id = order_id_param;

    final_amount := total_amount - discount_amount;
END;
$$;

-- 사용법
SELECT * FROM get_order_summary(1001);
```

### 5. 에러 핸들링

```sql
CREATE OR REPLACE FUNCTION safe_update_inventory(
    variant_id_param INTEGER,
    quantity_change INTEGER
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    current_stock INTEGER;
    error_msg TEXT;
BEGIN
    -- 현재 재고 조회
    SELECT stock_quantity INTO current_stock
    FROM inventory
    WHERE variant_id = variant_id_param
    FOR UPDATE;  -- 락 획득

    -- 재고 부족 체크
    IF current_stock + quantity_change < 0 THEN
        RAISE EXCEPTION 'Insufficient inventory: current=%, requested=%',
            current_stock, -quantity_change
            USING ERRCODE = '22000';  -- 사용자 정의 에러 코드
    END IF;

    -- 재고 업데이트
    UPDATE inventory
    SET stock_quantity = stock_quantity + quantity_change,
        updated_at = CURRENT_TIMESTAMP
    WHERE variant_id = variant_id_param;

    RETURN 'Success: updated inventory';

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 'Error: variant not found';
    WHEN SQLSTATE '22000' THEN
        -- 사용자 정의 에러
        GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
        RETURN 'Error: ' || error_msg;
    WHEN OTHERS THEN
        -- 모든 기타 에러
        GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
        RAISE WARNING 'Unexpected error: %', error_msg;
        RETURN 'Error: unexpected error occurred';
END;
$$;

-- 테스트
SELECT safe_update_inventory(1, -100);  -- 재고 감소
SELECT safe_update_inventory(999, 10);  -- 존재하지 않는 variant
```

#### 에러 정보 추출
```sql
CREATE OR REPLACE FUNCTION detailed_error_handling()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    err_context TEXT;
    err_detail TEXT;
    err_hint TEXT;
    err_message TEXT;
    err_sqlstate TEXT;
BEGIN
    -- 에러를 발생시킬 작업
    PERFORM 1/0;  -- Division by zero

    RETURN 'Success';

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
        err_context = PG_EXCEPTION_CONTEXT,
        err_detail = PG_EXCEPTION_DETAIL,
        err_hint = PG_EXCEPTION_HINT,
        err_message = MESSAGE_TEXT,
        err_sqlstate = RETURNED_SQLSTATE;

    RAISE WARNING 'Error Details:';
    RAISE WARNING 'SQLSTATE: %', err_sqlstate;
    RAISE WARNING 'Message: %', err_message;
    RAISE WARNING 'Context: %', err_context;

    RETURN format('Error: %s (SQLSTATE: %s)', err_message, err_sqlstate);
END;
$$;
```

### 6. 동적 SQL (EXECUTE)

```sql
CREATE OR REPLACE FUNCTION dynamic_search(
    table_name TEXT,
    search_column TEXT,
    search_value TEXT
)
RETURNS TABLE(result JSONB)
LANGUAGE plpgsql
AS $$
DECLARE
    query TEXT;
BEGIN
    -- SQL 인젝션 방지를 위한 검증
    IF table_name NOT IN ('products', 'users', 'orders') THEN
        RAISE EXCEPTION 'Invalid table name: %', table_name;
    END IF;

    -- 동적 쿼리 생성
    query := format(
        'SELECT row_to_json(t)::jsonb FROM %I t WHERE %I::text ILIKE $1',
        table_name,
        search_column
    );

    -- 동적 쿼리 실행 (파라미터 바인딩 사용)
    RETURN QUERY EXECUTE query USING '%' || search_value || '%';
END;
$$;

-- 사용 예시
SELECT * FROM dynamic_search('products', 'name', '노트북');
```

#### 동적 테이블 생성 예시
```sql
CREATE OR REPLACE PROCEDURE create_monthly_partition(
    base_table TEXT,
    partition_date DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    partition_name TEXT;
    start_date DATE;
    end_date DATE;
    create_sql TEXT;
BEGIN
    -- 파티션 이름 생성
    partition_name := format('%s_%s', base_table, TO_CHAR(partition_date, 'YYYY_MM'));
    start_date := DATE_TRUNC('month', partition_date);
    end_date := start_date + INTERVAL '1 month';

    -- 동적 DDL 생성 및 실행
    create_sql := format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF %I
         FOR VALUES FROM (%L) TO (%L)',
        partition_name,
        base_table,
        start_date,
        end_date
    );

    EXECUTE create_sql;

    RAISE NOTICE 'Created partition: %', partition_name;
    COMMIT;
END;
$$;

-- 사용 예시
CALL create_monthly_partition('event_logs', '2024-06-01');
```

## OS/파일시스템 관점

### 1. 함수/프로시저의 저장 위치

PL/pgSQL 함수와 프로시저는 **시스템 카탈로그**에 저장됩니다:

```sql
-- 함수/프로시저 정보 조회
SELECT
    p.proname AS name,
    pg_get_functiondef(p.oid) AS definition,
    CASE p.prokind
        WHEN 'f' THEN 'function'
        WHEN 'p' THEN 'procedure'
        WHEN 'a' THEN 'aggregate'
        WHEN 'w' THEN 'window'
    END AS type,
    pg_size_pretty(pg_column_size(p.prosrc)) AS source_size
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
ORDER BY p.proname;
```

**물리적 저장**:
- 위치: `$PGDATA/base/<database_oid>/` 디렉토리
- 카탈로그 테이블: `pg_proc` (함수/프로시저 메타데이터)
- 소스 코드: `prosrc` 컬럼에 TEXT로 저장
- 컴파일된 코드: 메모리에 캐시 (디스크에는 소스만 저장)

### 2. 함수 실행 시 메모리 사용

```bash
# PostgreSQL 프로세스의 메모리 사용량 확인 (Linux)
$ ps aux | grep postgres | grep "SELECT"

# 함수 실행 중 메모리 할당 추적
$ cat /proc/<postgres_pid>/status | grep Vm
VmPeak: 메모리 사용 최대값
VmSize: 현재 가상 메모리 크기
VmRSS:  물리 메모리 사용량
```

**메모리 구조**:
- **Per-function context**: 각 함수 호출마다 별도 메모리 컨텍스트 생성
- **변수 저장**: 로컬 변수는 함수 컨텍스트에 할당
- **반환값**: SETOF나 TABLE 반환 시 결과셋이 메모리에 누적될 수 있음
- **자동 정리**: 함수 종료 시 컨텍스트 전체 해제

### 3. 컴파일과 캐싱

```sql
-- 함수 실행 계획 및 캐시 정보 확인
SELECT * FROM pg_prepared_statements;

-- 함수 캐시 통계 (pg_stat_statements 필요)
SELECT
    calls,
    total_exec_time,
    mean_exec_time,
    query
FROM pg_stat_statements
WHERE query LIKE '%function_name%'
ORDER BY calls DESC;
```

**컴파일 프로세스**:
1. **첫 실행**: 소스 코드 파싱 → 내부 표현 생성 → 실행
2. **캐싱**: 컴파일된 함수 정의를 세션 메모리에 캐시
3. **재실행**: 캐시된 버전 사용 (파싱 생략)
4. **무효화**: 함수 재생성 시 모든 세션의 캐시 무효화

### 4. 트리거의 오버헤드

트리거는 각 행 또는 문장마다 실행되므로 성능 영향이 큽니다:

```sql
-- 트리거 실행 통계 확인
SELECT
    schemaname,
    tablename,
    n_tup_ins AS inserts,
    n_tup_upd AS updates,
    n_tup_del AS deletes
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_tup_upd DESC;
```

**성능 고려사항**:
- ROW 트리거는 각 행마다 함수 호출 → 대량 작업 시 느림
- STATEMENT 트리거는 문장당 1회만 실행 → 성능 우수
- 불필요한 트리거는 제거
- 복잡한 로직은 AFTER 트리거로 (BEFORE는 최소화)

## 트리거 설계 패턴

### 1. BEFORE vs AFTER 트리거

#### BEFORE 트리거 - 데이터 변경 전 검증 및 수정
```sql
-- updated_at 자동 갱신 (BEFORE UPDATE 트리거)
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;  -- BEFORE 트리거는 NEW를 반환해야 함
END;
$$;

-- 모든 테이블에 적용
CREATE TRIGGER set_updated_at_users
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_updated_at_products
    BEFORE UPDATE ON products
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_updated_at_orders
    BEFORE UPDATE ON orders
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();
```

#### BEFORE 트리거 - 데이터 검증
```sql
-- 주문 금액 검증 트리거
CREATE OR REPLACE FUNCTION trigger_validate_order_amount()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- 주문 금액이 음수인지 확인
    IF NEW.total_amount < 0 THEN
        RAISE EXCEPTION 'Order amount cannot be negative: %', NEW.total_amount;
    END IF;

    -- 비현실적으로 큰 금액 경고
    IF NEW.total_amount > 10000000 THEN
        RAISE WARNING 'Unusually large order amount: %', NEW.total_amount;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER validate_order_amount
    BEFORE INSERT OR UPDATE ON orders
    FOR EACH ROW
    EXECUTE FUNCTION trigger_validate_order_amount();
```

#### AFTER 트리거 - 감사 로그
```sql
-- 감사 로그 테이블 생성
CREATE TABLE audit_logs (
    audit_id BIGSERIAL PRIMARY KEY,
    table_name TEXT NOT NULL,
    operation TEXT NOT NULL,  -- INSERT, UPDATE, DELETE
    old_data JSONB,
    new_data JSONB,
    changed_by TEXT DEFAULT CURRENT_USER,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 범용 감사 로그 트리거 함수
CREATE OR REPLACE FUNCTION trigger_audit_log()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_logs (table_name, operation, new_data)
        VALUES (TG_TABLE_NAME, TG_OP, row_to_json(NEW)::jsonb);
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_logs (table_name, operation, old_data, new_data)
        VALUES (TG_TABLE_NAME, TG_OP, row_to_json(OLD)::jsonb, row_to_json(NEW)::jsonb);
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO audit_logs (table_name, operation, old_data)
        VALUES (TG_TABLE_NAME, TG_OP, row_to_json(OLD)::jsonb);
        RETURN OLD;
    END IF;
END;
$$;

-- 중요 테이블에 감사 로그 적용
CREATE TRIGGER audit_users
    AFTER INSERT OR UPDATE OR DELETE ON users
    FOR EACH ROW
    EXECUTE FUNCTION trigger_audit_log();

CREATE TRIGGER audit_orders
    AFTER INSERT OR UPDATE OR DELETE ON orders
    FOR EACH ROW
    EXECUTE FUNCTION trigger_audit_log();

CREATE TRIGGER audit_payments
    AFTER INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW
    EXECUTE FUNCTION trigger_audit_log();
```

### 2. ROW vs STATEMENT 트리거

```sql
-- ROW 레벨 트리거 (각 행마다 실행)
CREATE OR REPLACE FUNCTION trigger_row_level_example()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE 'Row-level trigger fired for product_id: %', NEW.product_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER row_level_trigger
    AFTER INSERT ON products
    FOR EACH ROW
    EXECUTE FUNCTION trigger_row_level_example();

-- STATEMENT 레벨 트리거 (문장당 1회 실행)
CREATE OR REPLACE FUNCTION trigger_statement_level_example()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE 'Statement-level trigger fired. Operation: %', TG_OP;
    -- NEW, OLD 사용 불가 (전체 변경셋 처리 필요)
    RETURN NULL;
END;
$$;

CREATE TRIGGER statement_level_trigger
    AFTER INSERT ON products
    FOR EACH STATEMENT
    EXECUTE FUNCTION trigger_statement_level_example();

-- 테스트
INSERT INTO products (name, price, category_id)
VALUES
    ('Product A', 10000, 1),
    ('Product B', 20000, 1),
    ('Product C', 30000, 2);
-- ROW 트리거: 3번 실행
-- STATEMENT 트리거: 1번 실행
```

### 3. 재고 자동 감소 트리거 (실무 패턴)

```sql
-- 주문 아이템 추가 시 재고 자동 감소
CREATE OR REPLACE FUNCTION trigger_decrease_inventory()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_stock INTEGER;
BEGIN
    -- 현재 재고 조회 및 락 획득
    SELECT stock_quantity INTO current_stock
    FROM inventory
    WHERE variant_id = NEW.variant_id
    FOR UPDATE;

    -- 재고 부족 확인
    IF current_stock IS NULL THEN
        RAISE EXCEPTION 'Inventory record not found for variant_id: %', NEW.variant_id;
    END IF;

    IF current_stock < NEW.quantity THEN
        RAISE EXCEPTION 'Insufficient inventory for variant_id %. Available: %, Requested: %',
            NEW.variant_id, current_stock, NEW.quantity;
    END IF;

    -- 재고 감소
    UPDATE inventory
    SET stock_quantity = stock_quantity - NEW.quantity,
        updated_at = CURRENT_TIMESTAMP
    WHERE variant_id = NEW.variant_id;

    RAISE NOTICE 'Decreased inventory for variant_id %: % → %',
        NEW.variant_id, current_stock, current_stock - NEW.quantity;

    RETURN NEW;
END;
$$;

CREATE TRIGGER decrease_inventory_on_order
    BEFORE INSERT ON order_items
    FOR EACH ROW
    EXECUTE FUNCTION trigger_decrease_inventory();

-- 주문 취소 시 재고 복구
CREATE OR REPLACE FUNCTION trigger_restore_inventory()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- 주문 상태가 'cancelled'로 변경된 경우에만 실행
    IF OLD.status != 'cancelled' AND NEW.status = 'cancelled' THEN
        -- 해당 주문의 모든 아이템 재고 복구
        UPDATE inventory i
        SET stock_quantity = stock_quantity + oi.quantity,
            updated_at = CURRENT_TIMESTAMP
        FROM order_items oi
        WHERE oi.order_id = NEW.order_id
          AND i.variant_id = oi.variant_id;

        RAISE NOTICE 'Restored inventory for cancelled order: %', NEW.order_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER restore_inventory_on_cancel
    AFTER UPDATE ON orders
    FOR EACH ROW
    EXECUTE FUNCTION trigger_restore_inventory();
```

### 4. 이벤트 트리거 (DDL 감지) - PostgreSQL 17

이벤트 트리거는 DDL 명령(CREATE, ALTER, DROP 등)을 감지하여 실행됩니다.

```sql
-- DDL 명령 로그 테이블
CREATE TABLE ddl_audit_log (
    log_id BIGSERIAL PRIMARY KEY,
    event_type TEXT NOT NULL,
    object_type TEXT,
    object_identity TEXT,
    command_tag TEXT,
    executed_by TEXT DEFAULT CURRENT_USER,
    executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    query_text TEXT
);

-- DDL 감사 이벤트 트리거
CREATE OR REPLACE FUNCTION event_trigger_ddl_audit()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
DECLARE
    obj RECORD;
BEGIN
    -- 생성/변경된 객체 정보 수집
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        INSERT INTO ddl_audit_log (
            event_type,
            object_type,
            object_identity,
            command_tag,
            query_text
        )
        VALUES (
            TG_EVENT,
            obj.object_type,
            obj.object_identity,
            obj.command_tag,
            current_query()
        );
    END LOOP;

    RAISE NOTICE 'DDL command logged: %', current_query();
END;
$$;

-- 이벤트 트리거 등록
CREATE EVENT TRIGGER audit_ddl_commands
    ON ddl_command_end
    EXECUTE FUNCTION event_trigger_ddl_audit();

-- DROP 명령 감지 (ddl_command_end 이전에 실행)
CREATE OR REPLACE FUNCTION event_trigger_prevent_drop()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
DECLARE
    obj RECORD;
BEGIN
    -- 삭제되는 객체 정보
    FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects()
    LOOP
        -- 중요 테이블 삭제 방지
        IF obj.object_type = 'table' AND obj.object_identity LIKE '%users%' THEN
            RAISE EXCEPTION 'Cannot drop critical table: %', obj.object_identity;
        END IF;

        RAISE WARNING 'Dropping %: %', obj.object_type, obj.object_identity;
    END LOOP;
END;
$$;

CREATE EVENT TRIGGER prevent_critical_drops
    ON sql_drop
    EXECUTE FUNCTION event_trigger_prevent_drop();

-- 테스트
CREATE TABLE test_table (id INTEGER);  -- ddl_audit_log에 기록됨
DROP TABLE test_table;  -- 경고 발생, audit_log에 기록됨
-- DROP TABLE users;  -- 에러 발생 (방지됨)
```

**PostgreSQL 17의 이벤트 트리거 개선사항**:
- 더 세밀한 객체 정보 제공
- 성능 최적화
- 더 많은 DDL 명령 지원

## 커스텀 타입과 도메인

### 1. 복합 타입 (Composite Type)

```sql
-- 주소 복합 타입 정의
CREATE TYPE address_type AS (
    street TEXT,
    city TEXT,
    state TEXT,
    postal_code TEXT,
    country TEXT
);

-- 복합 타입을 사용하는 함수
CREATE OR REPLACE FUNCTION format_address(addr address_type)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN format('%s, %s, %s %s, %s',
        addr.street,
        addr.city,
        addr.state,
        addr.postal_code,
        addr.country
    );
END;
$$;

-- 사용 예시
SELECT format_address(ROW('123 Main St', 'Seoul', 'Seoul', '12345', 'Korea')::address_type);

-- 테이블에 복합 타입 사용
CREATE TABLE customer_addresses (
    customer_id INTEGER,
    billing_address address_type,
    shipping_address address_type
);
```

### 2. 열거형 (ENUM Type)

```sql
-- 주문 상태 열거형
CREATE TYPE order_status_enum AS ENUM (
    'pending',
    'confirmed',
    'paid',
    'shipping',
    'delivered',
    'cancelled',
    'refunded'
);

-- 열거형을 사용하는 테이블
CREATE TABLE orders_with_enum (
    order_id SERIAL PRIMARY KEY,
    status order_status_enum DEFAULT 'pending',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 열거형 값 추가 (PostgreSQL 17)
ALTER TYPE order_status_enum ADD VALUE 'processing' AFTER 'confirmed';

-- 열거형 값 이름 변경 (PostgreSQL 17)
ALTER TYPE order_status_enum RENAME VALUE 'refunded' TO 'refund_completed';

-- 열거형을 사용하는 함수
CREATE OR REPLACE FUNCTION get_order_status_sequence(current_status order_status_enum)
RETURNS order_status_enum[]
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN CASE current_status
        WHEN 'pending' THEN ARRAY['confirmed', 'paid', 'shipping', 'delivered']::order_status_enum[]
        WHEN 'confirmed' THEN ARRAY['paid', 'shipping', 'delivered']::order_status_enum[]
        WHEN 'paid' THEN ARRAY['shipping', 'delivered']::order_status_enum[]
        ELSE ARRAY[]::order_status_enum[]
    END;
END;
$$;
```

### 3. 도메인 (Domain)

도메인은 기존 타입에 제약조건을 추가한 사용자 정의 타입입니다.

```sql
-- 이메일 도메인
CREATE DOMAIN email_address AS TEXT
CHECK (
    VALUE ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
);

-- 전화번호 도메인 (한국)
CREATE DOMAIN phone_number AS TEXT
CHECK (
    VALUE ~ '^\d{2,3}-\d{3,4}-\d{4}$'
);

-- 가격 도메인 (양수만 허용)
CREATE DOMAIN positive_price AS NUMERIC(12,2)
CHECK (VALUE >= 0);

-- 재고 수량 도메인
CREATE DOMAIN stock_quantity AS INTEGER
CHECK (VALUE >= 0)
DEFAULT 0;

-- 도메인을 사용하는 테이블
CREATE TABLE products_with_domains (
    product_id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    price positive_price NOT NULL,
    stock stock_quantity,
    contact_email email_address,
    contact_phone phone_number
);

-- 테스트
INSERT INTO products_with_domains (name, price, contact_email)
VALUES ('Test Product', 10000, 'test@example.com');  -- 성공

-- INSERT INTO products_with_domains (name, price)
-- VALUES ('Test', -100);  -- 에러: price는 양수여야 함

-- INSERT INTO products_with_domains (name, price, contact_email)
-- VALUES ('Test', 100, 'invalid-email');  -- 에러: 이메일 형식 불일치
```

### 4. 범위 타입 (Range Type)

```sql
-- 커스텀 범위 타입
CREATE TYPE price_range AS RANGE (
    SUBTYPE = NUMERIC,
    SUBTYPE_DIFF = float8mi
);

-- 범위 타입을 사용하는 함수
CREATE OR REPLACE FUNCTION find_products_in_price_range(range_param price_range)
RETURNS TABLE(product_id INTEGER, name TEXT, price NUMERIC)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT p.product_id, p.name, p.price
    FROM products p
    WHERE p.price <@ range_param  -- 포함 연산자
    ORDER BY p.price;
END;
$$;

-- 사용 예시
SELECT * FROM find_products_in_price_range('[10000,50000]'::price_range);
```

## PostgreSQL 17: 함수의 search_path 변경사항

PostgreSQL 17에서는 함수의 `search_path` 처리가 더 안전하게 개선되었습니다.

```sql
-- PostgreSQL 17 이전: 기본 search_path 사용 (보안 위험)
CREATE FUNCTION old_style_function()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- 호출자의 search_path 영향을 받음
    RETURN (SELECT COUNT(*) FROM users);  -- 어느 스키마의 users?
END;
$$;

-- PostgreSQL 17: 명시적 search_path 지정 (권장)
CREATE FUNCTION secure_function()
RETURNS INTEGER
LANGUAGE plpgsql
SET search_path = public, pg_temp  -- 명시적 지정
AS $$
BEGIN
    -- 항상 public.users를 참조
    RETURN (SELECT COUNT(*) FROM users);
END;
$$;

-- 함수별 search_path 확인
SELECT
    p.proname,
    pg_get_function_identity_arguments(p.oid) AS arguments,
    p.proconfig AS search_path_config
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND p.proname LIKE '%function%';
```

**보안 권장사항**:
1. 모든 함수에 명시적으로 `SET search_path` 지정
2. `SECURITY DEFINER` 함수는 반드시 `search_path` 설정
3. 스키마 이름을 명시적으로 지정 (예: `public.users`)

```sql
-- 보안이 강화된 함수 예시
CREATE OR REPLACE FUNCTION secure_get_user_count()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER  -- 함수 소유자 권한으로 실행
SET search_path = public, pg_temp  -- 명시적 경로
AS $$
BEGIN
    -- 스키마까지 명시
    RETURN (SELECT COUNT(*) FROM public.users);
END;
$$;
```

## 실습 SQL

### 실습 1: 주문 처리 함수 작성

```sql
-- 주문 생성 함수 (트랜잭션 내 여러 작업 수행)
CREATE OR REPLACE FUNCTION create_order(
    p_user_id INTEGER,
    p_items JSONB,  -- [{"variant_id": 1, "quantity": 2}, ...]
    p_coupon_code TEXT DEFAULT NULL
)
RETURNS INTEGER  -- 생성된 order_id 반환
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_id INTEGER;
    v_coupon_id INTEGER;
    v_discount_amount NUMERIC := 0;
    v_total_amount NUMERIC := 0;
    v_item JSONB;
    v_variant_id INTEGER;
    v_quantity INTEGER;
    v_price NUMERIC;
BEGIN
    -- 1. 쿠폰 검증 및 할인 금액 계산
    IF p_coupon_code IS NOT NULL THEN
        SELECT coupon_id, discount_amount
        INTO v_coupon_id, v_discount_amount
        FROM coupons
        WHERE code = p_coupon_code
          AND is_active = TRUE
          AND valid_from <= CURRENT_TIMESTAMP
          AND valid_until >= CURRENT_TIMESTAMP
          AND usage_limit > (SELECT COUNT(*) FROM coupon_usages WHERE coupon_id = coupons.coupon_id);

        IF v_coupon_id IS NULL THEN
            RAISE EXCEPTION 'Invalid or expired coupon code: %', p_coupon_code;
        END IF;
    END IF;

    -- 2. 주문 생성
    INSERT INTO orders (user_id, status, coupon_id, created_at)
    VALUES (p_user_id, 'pending', v_coupon_id, CURRENT_TIMESTAMP)
    RETURNING order_id INTO v_order_id;

    -- 3. 주문 아이템 추가 및 금액 계산
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_variant_id := (v_item->>'variant_id')::INTEGER;
        v_quantity := (v_item->>'quantity')::INTEGER;

        -- 상품 가격 조회
        SELECT pv.price INTO v_price
        FROM product_variants pv
        WHERE pv.variant_id = v_variant_id;

        IF v_price IS NULL THEN
            RAISE EXCEPTION 'Product variant not found: %', v_variant_id;
        END IF;

        -- 주문 아이템 추가
        INSERT INTO order_items (order_id, variant_id, quantity, price)
        VALUES (v_order_id, v_variant_id, v_quantity, v_price);

        -- 재고는 트리거가 자동 감소

        v_total_amount := v_total_amount + (v_price * v_quantity);
    END LOOP;

    -- 4. 주문 금액 업데이트
    UPDATE orders
    SET total_amount = v_total_amount - v_discount_amount
    WHERE order_id = v_order_id;

    -- 5. 쿠폰 사용 기록
    IF v_coupon_id IS NOT NULL THEN
        INSERT INTO coupon_usages (coupon_id, user_id, order_id, used_at)
        VALUES (v_coupon_id, p_user_id, v_order_id, CURRENT_TIMESTAMP);
    END IF;

    RAISE NOTICE 'Order created: order_id=%, total=%', v_order_id, v_total_amount - v_discount_amount;

    RETURN v_order_id;
END;
$$;

-- 테스트
SELECT create_order(
    1,  -- user_id
    '[
        {"variant_id": 1, "quantity": 2},
        {"variant_id": 3, "quantity": 1}
    ]'::jsonb,
    'WELCOME10'  -- coupon_code
);
```

### 실습 2: 배치 처리 프로시저

```sql
-- 만료된 장바구니 정리 프로시저
CREATE OR REPLACE PROCEDURE cleanup_expired_carts(days_old INTEGER DEFAULT 30)
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted_carts INTEGER := 0;
    v_deleted_items INTEGER := 0;
    v_batch_size INTEGER := 1000;
    v_affected_rows INTEGER;
BEGIN
    RAISE NOTICE 'Starting cleanup of carts older than % days', days_old;

    LOOP
        -- 배치 단위로 처리
        WITH expired_carts AS (
            SELECT cart_id
            FROM carts
            WHERE updated_at < CURRENT_TIMESTAMP - (days_old || ' days')::INTERVAL
            LIMIT v_batch_size
        )
        DELETE FROM cart_items
        WHERE cart_id IN (SELECT cart_id FROM expired_carts);

        GET DIAGNOSTICS v_affected_rows = ROW_COUNT;
        v_deleted_items := v_deleted_items + v_affected_rows;

        EXIT WHEN v_affected_rows = 0;

        COMMIT;  -- 배치마다 커밋 (프로시저만 가능)
        RAISE NOTICE 'Deleted % cart items so far...', v_deleted_items;
    END LOOP;

    -- 카트 삭제
    LOOP
        WITH expired_carts AS (
            SELECT cart_id
            FROM carts
            WHERE updated_at < CURRENT_TIMESTAMP - (days_old || ' days')::INTERVAL
            LIMIT v_batch_size
        )
        DELETE FROM carts
        WHERE cart_id IN (SELECT cart_id FROM expired_carts);

        GET DIAGNOSTICS v_affected_rows = ROW_COUNT;
        v_deleted_carts := v_deleted_carts + v_affected_rows;

        EXIT WHEN v_affected_rows = 0;

        COMMIT;
        RAISE NOTICE 'Deleted % carts so far...', v_deleted_carts;
    END LOOP;

    RAISE NOTICE 'Cleanup complete: % carts, % items deleted', v_deleted_carts, v_deleted_items;
END;
$$;

-- 실행
CALL cleanup_expired_carts(30);
```

### 실습 3: 리뷰 통계 집계 함수

```sql
-- 상품별 리뷰 통계 업데이트 함수
CREATE OR REPLACE FUNCTION update_product_review_stats(p_product_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_avg_rating NUMERIC;
    v_review_count INTEGER;
BEGIN
    -- 리뷰 통계 계산
    SELECT
        COALESCE(AVG(rating), 0),
        COUNT(*)
    INTO v_avg_rating, v_review_count
    FROM reviews
    WHERE product_id = p_product_id;

    -- products 테이블에 통계 업데이트
    UPDATE products
    SET
        average_rating = ROUND(v_avg_rating, 2),
        review_count = v_review_count,
        updated_at = CURRENT_TIMESTAMP
    WHERE product_id = p_product_id;

    RAISE NOTICE 'Updated review stats for product %: avg=%, count=%',
        p_product_id, v_avg_rating, v_review_count;
END;
$$;

-- 리뷰 추가/수정/삭제 시 자동으로 통계 업데이트하는 트리거
CREATE OR REPLACE FUNCTION trigger_update_review_stats()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM update_product_review_stats(OLD.product_id);
        RETURN OLD;
    ELSE
        PERFORM update_product_review_stats(NEW.product_id);
        RETURN NEW;
    END IF;
END;
$$;

CREATE TRIGGER update_review_stats_on_change
    AFTER INSERT OR UPDATE OR DELETE ON reviews
    FOR EACH ROW
    EXECUTE FUNCTION trigger_update_review_stats();
```

## 직접 확인해보기

### 1. 함수 성능 측정

```sql
-- 실행 시간 측정
\timing on

-- 함수 실행
SELECT create_order(1, '[{"variant_id": 1, "quantity": 1}]'::jsonb);

-- 여러 번 실행하여 평균 시간 측정
DO $$
DECLARE
    start_time TIMESTAMP;
    end_time TIMESTAMP;
    i INTEGER;
BEGIN
    start_time := clock_timestamp();

    FOR i IN 1..100 LOOP
        PERFORM calculate_order_total(i);
    END LOOP;

    end_time := clock_timestamp();

    RAISE NOTICE 'Average execution time: % ms',
        EXTRACT(MILLISECONDS FROM (end_time - start_time)) / 100;
END $$;
```

### 2. 트리거 실행 확인

```sql
-- 트리거 목록 확인
SELECT
    t.tgname AS trigger_name,
    c.relname AS table_name,
    p.proname AS function_name,
    CASE t.tgtype::INTEGER & 1
        WHEN 1 THEN 'ROW'
        ELSE 'STATEMENT'
    END AS level,
    CASE t.tgtype::INTEGER & 66
        WHEN 2 THEN 'BEFORE'
        WHEN 64 THEN 'INSTEAD OF'
        ELSE 'AFTER'
    END AS timing,
    CASE
        WHEN t.tgtype::INTEGER & 4 != 0 THEN 'INSERT '
        ELSE ''
    END ||
    CASE
        WHEN t.tgtype::INTEGER & 8 != 0 THEN 'DELETE '
        ELSE ''
    END ||
    CASE
        WHEN t.tgtype::INTEGER & 16 != 0 THEN 'UPDATE '
        ELSE ''
    END AS events
FROM pg_trigger t
JOIN pg_class c ON t.tgrelid = c.oid
JOIN pg_proc p ON t.tgfoid = p.oid
WHERE NOT t.tgisinternal
ORDER BY c.relname, t.tgname;
```

### 3. 함수 소스 코드 확인

```sql
-- 함수 정의 전체 보기
SELECT pg_get_functiondef('create_order'::regproc);

-- 함수 목록과 기본 정보
SELECT
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS arguments,
    pg_get_functiondef(p.oid) AS definition
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND p.prokind = 'f'  -- 'f' = function, 'p' = procedure
ORDER BY p.proname;
```

### 4. 에러 처리 테스트

```sql
-- 재고 부족 에러 테스트
BEGIN;
    -- 재고를 0으로 설정
    UPDATE inventory SET stock_quantity = 0 WHERE variant_id = 1;

    -- 주문 생성 시도 (재고 부족 에러 발생)
    SELECT create_order(1, '[{"variant_id": 1, "quantity": 5}]'::jsonb);
ROLLBACK;

-- 유효하지 않은 쿠폰 테스트
SELECT create_order(1, '[{"variant_id": 1, "quantity": 1}]'::jsonb, 'INVALID_COUPON');
```

## 실무 팁

### 1. 함수 vs 프로시저 선택 기준

**함수 사용**:
- 계산 결과를 반환해야 할 때
- SELECT 문에서 사용해야 할 때
- 읽기 전용 작업
- 단일 트랜잭션으로 충분할 때

**프로시저 사용**:
- 대량 데이터 처리 (배치 작업)
- 중간에 COMMIT이 필요할 때
- 복잡한 트랜잭션 제어가 필요할 때
- 여러 단계로 나누어 처리해야 할 때

### 2. 성능 최적화

```sql
-- 나쁜 예: 함수 안에서 반복적인 쿼리
CREATE FUNCTION slow_function()
RETURNS VOID AS $$
DECLARE
    user_rec RECORD;
BEGIN
    FOR user_rec IN SELECT user_id FROM users LOOP
        -- 각 사용자마다 쿼리 실행 (N+1 문제)
        UPDATE orders SET processed = TRUE
        WHERE user_id = user_rec.user_id;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 좋은 예: 단일 쿼리로 처리
CREATE FUNCTION fast_function()
RETURNS VOID AS $$
BEGIN
    -- 한 번의 쿼리로 모두 처리
    UPDATE orders SET processed = TRUE
    WHERE user_id IN (SELECT user_id FROM users);
END;
$$ LANGUAGE plpgsql;
```

### 3. 트리거 사용 시 주의사항

**피해야 할 패턴**:
- 트리거 안에서 같은 테이블 수정 (무한 루프 위험)
- 과도하게 복잡한 로직 (성능 저하)
- 트리거 체인 (A 트리거 → B 트리거 → C 트리거, 디버깅 어려움)

**권장 패턴**:
- 단순하고 명확한 로직
- BEFORE 트리거: 검증 및 데이터 변환
- AFTER 트리거: 로깅 및 후속 작업
- 복잡한 로직은 함수로 분리

### 4. 에러 처리 전략

```sql
-- 상세한 에러 정보 제공
CREATE FUNCTION safe_function(param INTEGER)
RETURNS TEXT AS $$
BEGIN
    -- 비즈니스 로직
    IF param < 0 THEN
        RAISE EXCEPTION 'Invalid parameter: % (must be positive)', param
            USING
                HINT = 'Please provide a positive number',
                ERRCODE = '22000';
    END IF;

    RETURN 'Success';
EXCEPTION
    WHEN OTHERS THEN
        -- 에러 로깅
        INSERT INTO error_logs (error_message, error_context)
        VALUES (SQLERRM, SQLSTATE);

        -- 사용자 친화적 메시지 반환
        RETURN 'An error occurred. Please contact support.';
END;
$$ LANGUAGE plpgsql;
```

### 5. 동적 SQL 보안

```sql
-- 나쁜 예: SQL 인젝션 취약
CREATE FUNCTION unsafe_search(table_name TEXT, value TEXT)
RETURNS SETOF RECORD AS $$
BEGIN
    -- 위험! 사용자 입력을 직접 삽입
    RETURN QUERY EXECUTE 'SELECT * FROM ' || table_name ||
                         ' WHERE name = ''' || value || '''';
END;
$$ LANGUAGE plpgsql;

-- 좋은 예: 파라미터 바인딩 사용
CREATE FUNCTION safe_search(table_name TEXT, value TEXT)
RETURNS SETOF RECORD AS $$
BEGIN
    -- 테이블 이름 검증
    IF table_name NOT IN ('products', 'users', 'orders') THEN
        RAISE EXCEPTION 'Invalid table name';
    END IF;

    -- 파라미터 바인딩 사용
    RETURN QUERY EXECUTE
        format('SELECT * FROM %I WHERE name = $1', table_name)
        USING value;
END;
$$ LANGUAGE plpgsql;
```

### 6. 테스트 전략

```sql
-- 단위 테스트 함수
CREATE OR REPLACE FUNCTION test_create_order()
RETURNS TEXT AS $$
DECLARE
    test_order_id INTEGER;
    test_result TEXT := 'PASSED';
BEGIN
    -- 테스트 데이터 준비
    BEGIN
        -- 주문 생성 테스트
        test_order_id := create_order(
            1,
            '[{"variant_id": 1, "quantity": 1}]'::jsonb
        );

        -- 결과 검증
        IF test_order_id IS NULL THEN
            test_result := 'FAILED: order_id is NULL';
        END IF;

        -- 클린업
        DELETE FROM order_items WHERE order_id = test_order_id;
        DELETE FROM orders WHERE order_id = test_order_id;

    EXCEPTION WHEN OTHERS THEN
        test_result := 'FAILED: ' || SQLERRM;
    END;

    RETURN test_result;
END;
$$ LANGUAGE plpgsql;

-- 테스트 실행
SELECT test_create_order();
```

## 참고 링크

### 공식 PostgreSQL 17 문서
- [Chapter 41: PL/pgSQL - SQL Procedural Language](https://www.postgresql.org/docs/17/plpgsql.html)
- [Chapter 37: Triggers](https://www.postgresql.org/docs/17/triggers.html)
- [Chapter 36: Extending SQL](https://www.postgresql.org/docs/17/extend.html)
- [Chapter 38: Event Triggers](https://www.postgresql.org/docs/17/event-triggers.html)
- [Chapter 8.16: Composite Types](https://www.postgresql.org/docs/17/rowtypes.html)
- [Chapter 8.7: Enumerated Types](https://www.postgresql.org/docs/17/datatype-enum.html)
- [Chapter 8.18: Domain Types](https://www.postgresql.org/docs/17/domains.html)

### PostgreSQL 17 릴리스 노트
- [PostgreSQL 17 Release Notes - PL/pgSQL Changes](https://www.postgresql.org/docs/17/release-17.html)

### 추가 학습 자료
- PostgreSQL Wiki: PL/pgSQL Best Practices
- PostgreSQL Performance Blog: Function Optimization
- PL/pgSQL Debugger (pgAdmin, VS Code extensions)
