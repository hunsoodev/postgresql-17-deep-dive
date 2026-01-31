-- =============================================================================
-- 이커머스 쇼핑몰 실습 스키마 + 대량 테스트 데이터 생성
-- PostgreSQL 17 학습 프로젝트
-- =============================================================================

-- 확장 모듈 설치
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS pg_buffercache;
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- =============================================================================
-- 1. 회원
-- =============================================================================
CREATE TABLE users (
    user_id       BIGSERIAL PRIMARY KEY,
    email         VARCHAR(255) NOT NULL UNIQUE,
    username      VARCHAR(50) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    phone         VARCHAR(20),
    is_active     BOOLEAN DEFAULT true,
    created_at    TIMESTAMPTZ DEFAULT now(),
    updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE addresses (
    address_id  BIGSERIAL PRIMARY KEY,
    user_id     BIGINT NOT NULL REFERENCES users(user_id),
    label       VARCHAR(50) DEFAULT '기본',       -- 집, 회사 등
    recipient   VARCHAR(100) NOT NULL,
    phone       VARCHAR(20) NOT NULL,
    zip_code    VARCHAR(10) NOT NULL,
    address1    VARCHAR(255) NOT NULL,
    address2    VARCHAR(255),
    is_default  BOOLEAN DEFAULT false,
    created_at  TIMESTAMPTZ DEFAULT now()
);

-- =============================================================================
-- 2. 상품 카탈로그
-- =============================================================================
CREATE TABLE categories (
    category_id   SERIAL PRIMARY KEY,
    parent_id     INT REFERENCES categories(category_id),
    name          VARCHAR(100) NOT NULL,
    slug          VARCHAR(100) NOT NULL UNIQUE,
    depth         INT NOT NULL DEFAULT 0
);

CREATE TABLE products (
    product_id    BIGSERIAL PRIMARY KEY,
    category_id   INT NOT NULL REFERENCES categories(category_id),
    name          VARCHAR(255) NOT NULL,
    slug          VARCHAR(255) NOT NULL UNIQUE,
    description   TEXT,
    base_price    NUMERIC(12,2) NOT NULL,
    is_active     BOOLEAN DEFAULT true,
    metadata      JSONB DEFAULT '{}',       -- 브랜드, 태그 등 유연한 속성
    created_at    TIMESTAMPTZ DEFAULT now(),
    updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE product_variants (
    variant_id    BIGSERIAL PRIMARY KEY,
    product_id    BIGINT NOT NULL REFERENCES products(product_id),
    sku           VARCHAR(50) NOT NULL UNIQUE,
    name          VARCHAR(100) NOT NULL,      -- 예: "블랙 / XL"
    price         NUMERIC(12,2) NOT NULL,
    attributes    JSONB DEFAULT '{}',         -- {"color": "black", "size": "XL"}
    created_at    TIMESTAMPTZ DEFAULT now()
);

-- =============================================================================
-- 3. 재고
-- =============================================================================
CREATE TABLE inventory (
    inventory_id  BIGSERIAL PRIMARY KEY,
    variant_id    BIGINT NOT NULL REFERENCES product_variants(variant_id) UNIQUE,
    quantity      INT NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    reserved      INT NOT NULL DEFAULT 0 CHECK (reserved >= 0),
    updated_at    TIMESTAMPTZ DEFAULT now()
);

-- =============================================================================
-- 4. 장바구니
-- =============================================================================
CREATE TABLE carts (
    cart_id     BIGSERIAL PRIMARY KEY,
    user_id     BIGINT NOT NULL REFERENCES users(user_id),
    created_at  TIMESTAMPTZ DEFAULT now(),
    updated_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE cart_items (
    cart_item_id  BIGSERIAL PRIMARY KEY,
    cart_id       BIGINT NOT NULL REFERENCES carts(cart_id) ON DELETE CASCADE,
    variant_id    BIGINT NOT NULL REFERENCES product_variants(variant_id),
    quantity      INT NOT NULL DEFAULT 1 CHECK (quantity > 0),
    added_at      TIMESTAMPTZ DEFAULT now(),
    UNIQUE(cart_id, variant_id)
);

-- =============================================================================
-- 5. 주문 / 결제
-- =============================================================================
CREATE TABLE orders (
    order_id      BIGSERIAL PRIMARY KEY,
    user_id       BIGINT NOT NULL REFERENCES users(user_id),
    status        VARCHAR(20) NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','paid','shipping','delivered','cancelled','refunded')),
    total_amount  NUMERIC(12,2) NOT NULL,
    address_snapshot JSONB NOT NULL,          -- 주문 시점의 배송지 스냅샷
    created_at    TIMESTAMPTZ DEFAULT now(),
    updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE order_items (
    order_item_id BIGSERIAL PRIMARY KEY,
    order_id      BIGINT NOT NULL REFERENCES orders(order_id),
    variant_id    BIGINT NOT NULL REFERENCES product_variants(variant_id),
    quantity      INT NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(12,2) NOT NULL,
    subtotal      NUMERIC(12,2) NOT NULL
);

CREATE TABLE payments (
    payment_id    BIGSERIAL PRIMARY KEY,
    order_id      BIGINT NOT NULL REFERENCES orders(order_id),
    method        VARCHAR(30) NOT NULL CHECK (method IN ('card','bank_transfer','virtual_account')),
    amount        NUMERIC(12,2) NOT NULL,
    status        VARCHAR(20) NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','completed','failed','refunded')),
    pg_txn_id     VARCHAR(100),               -- PG사 거래 ID
    paid_at       TIMESTAMPTZ,
    created_at    TIMESTAMPTZ DEFAULT now()
);

-- =============================================================================
-- 6. 배송
-- =============================================================================
CREATE TABLE shipments (
    shipment_id   BIGSERIAL PRIMARY KEY,
    order_id      BIGINT NOT NULL REFERENCES orders(order_id),
    carrier       VARCHAR(50),
    tracking_no   VARCHAR(100),
    status        VARCHAR(20) NOT NULL DEFAULT 'preparing'
                  CHECK (status IN ('preparing','shipped','in_transit','delivered')),
    shipped_at    TIMESTAMPTZ,
    delivered_at  TIMESTAMPTZ,
    created_at    TIMESTAMPTZ DEFAULT now()
);

-- =============================================================================
-- 7. 쿠폰
-- =============================================================================
CREATE TABLE coupons (
    coupon_id     SERIAL PRIMARY KEY,
    code          VARCHAR(50) NOT NULL UNIQUE,
    discount_type VARCHAR(10) NOT NULL CHECK (discount_type IN ('percent','fixed')),
    discount_value NUMERIC(12,2) NOT NULL,
    min_order_amount NUMERIC(12,2) DEFAULT 0,
    max_uses      INT,
    used_count    INT DEFAULT 0,
    valid_from    TIMESTAMPTZ NOT NULL,
    valid_until   TIMESTAMPTZ NOT NULL,
    is_active     BOOLEAN DEFAULT true,
    created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE coupon_usages (
    usage_id    BIGSERIAL PRIMARY KEY,
    coupon_id   INT NOT NULL REFERENCES coupons(coupon_id),
    user_id     BIGINT NOT NULL REFERENCES users(user_id),
    order_id    BIGINT NOT NULL REFERENCES orders(order_id),
    used_at     TIMESTAMPTZ DEFAULT now(),
    UNIQUE(coupon_id, user_id, order_id)
);

-- =============================================================================
-- 8. 리뷰
-- =============================================================================
CREATE TABLE reviews (
    review_id     BIGSERIAL PRIMARY KEY,
    product_id    BIGINT NOT NULL REFERENCES products(product_id),
    user_id       BIGINT NOT NULL REFERENCES users(user_id),
    order_id      BIGINT REFERENCES orders(order_id),
    rating        SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    title         VARCHAR(200),
    body          TEXT,
    metadata      JSONB DEFAULT '{}',         -- {"verified": true, "helpful_count": 5}
    created_at    TIMESTAMPTZ DEFAULT now(),
    updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE review_images (
    image_id    BIGSERIAL PRIMARY KEY,
    review_id   BIGINT NOT NULL REFERENCES reviews(review_id) ON DELETE CASCADE,
    url         VARCHAR(500) NOT NULL,
    sort_order  SMALLINT DEFAULT 0,
    created_at  TIMESTAMPTZ DEFAULT now()
);

-- =============================================================================
-- 9. 이벤트 로그 (시계열 / 파티셔닝 실습용)
-- =============================================================================
CREATE TABLE event_logs (
    event_id    BIGSERIAL,
    user_id     BIGINT,
    event_type  VARCHAR(50) NOT NULL,
    payload     JSONB DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (created_at, event_id)
) PARTITION BY RANGE (created_at);

-- 월별 파티션 (2024-01 ~ 2025-06)
DO $$
DECLARE
    start_date DATE := '2024-01-01';
    end_date   DATE;
    part_name  TEXT;
BEGIN
    FOR i IN 0..17 LOOP
        end_date := start_date + INTERVAL '1 month';
        part_name := 'event_logs_' || to_char(start_date, 'YYYY_MM');
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF event_logs FOR VALUES FROM (%L) TO (%L)',
            part_name, start_date, end_date
        );
        start_date := end_date;
    END LOOP;
END $$;

-- =============================================================================
-- 인덱스 (기본)
-- =============================================================================
CREATE INDEX idx_addresses_user      ON addresses(user_id);
CREATE INDEX idx_products_category   ON products(category_id);
CREATE INDEX idx_products_metadata   ON products USING gin(metadata);
CREATE INDEX idx_variants_product    ON product_variants(product_id);
CREATE INDEX idx_cart_items_cart     ON cart_items(cart_id);
CREATE INDEX idx_orders_user         ON orders(user_id);
CREATE INDEX idx_orders_created      ON orders(created_at);
CREATE INDEX idx_orders_status       ON orders(status);
CREATE INDEX idx_order_items_order   ON order_items(order_id);
CREATE INDEX idx_payments_order      ON payments(order_id);
CREATE INDEX idx_shipments_order     ON shipments(order_id);
CREATE INDEX idx_reviews_product     ON reviews(product_id);
CREATE INDEX idx_reviews_user        ON reviews(user_id);
CREATE INDEX idx_event_logs_user     ON event_logs(user_id);
CREATE INDEX idx_event_logs_type     ON event_logs(event_type);

-- =============================================================================
-- 테스트 데이터 생성 (generate_series 활용)
-- =============================================================================

-- 카테고리 (3레벨 계층)
INSERT INTO categories (category_id, parent_id, name, slug, depth) VALUES
    (1,  NULL, '전자제품',     'electronics',      0),
    (2,  NULL, '의류',         'clothing',          0),
    (3,  NULL, '식품',         'food',              0),
    (4,  NULL, '도서',         'books',             0),
    (5,  1,    '스마트폰',     'smartphones',       1),
    (6,  1,    '노트북',       'laptops',           1),
    (7,  1,    '태블릿',       'tablets',           1),
    (8,  2,    '남성의류',     'mens-clothing',     1),
    (9,  2,    '여성의류',     'womens-clothing',   1),
    (10, 2,    '아동의류',     'kids-clothing',     1),
    (11, 3,    '과일',         'fruits',            1),
    (12, 3,    '음료',         'beverages',         1),
    (13, 4,    'IT/프로그래밍', 'it-programming',   1),
    (14, 4,    '소설',         'novels',            1),
    (15, 5,    '안드로이드폰', 'android-phones',    2),
    (16, 5,    '아이폰',       'iphones',           2),
    (17, 6,    '게이밍노트북', 'gaming-laptops',    2),
    (18, 6,    '비즈니스노트북','business-laptops',  2);

SELECT setval('categories_category_id_seq', 18);

-- 사용자 10만 명
INSERT INTO users (email, username, password_hash, phone, created_at)
SELECT
    'user' || n || '@example.com',
    'user' || n,
    md5(random()::text),
    '010-' || lpad((random()*9999)::int::text, 4, '0') || '-' || lpad((random()*9999)::int::text, 4, '0'),
    timestamp '2023-01-01' + random() * (timestamp '2025-06-01' - timestamp '2023-01-01')
FROM generate_series(1, 100000) AS n;

-- 배송지 (사용자 60%가 1~2개)
INSERT INTO addresses (user_id, recipient, phone, zip_code, address1, is_default)
SELECT
    user_id,
    username,
    phone,
    lpad((random()*99999)::int::text, 5, '0'),
    '서울시 ' || (ARRAY['강남구','서초구','마포구','종로구','성동구','용산구','영등포구','송파구'])[floor(random()*8+1)::int] || ' ' || floor(random()*300+1)::int || '번길 ' || floor(random()*50+1)::int,
    true
FROM users
WHERE random() < 0.6;

-- 상품 5000개
INSERT INTO products (category_id, name, slug, description, base_price, metadata, created_at)
SELECT
    (ARRAY[5,6,7,8,9,10,11,12,13,14,15,16,17,18])[floor(random()*14+1)::int],
    '상품 #' || n,
    'product-' || n,
    '이것은 상품 #' || n || '의 상세 설명입니다. 다양한 특징과 장점이 있습니다.',
    round((random() * 500000 + 1000)::numeric, 2),
    jsonb_build_object(
        'brand', (ARRAY['삼성','LG','애플','나이키','아디다스','무인양품','기타'])[floor(random()*7+1)::int],
        'tags', jsonb_build_array(
            (ARRAY['인기','신상','할인','한정','베스트'])[floor(random()*5+1)::int],
            (ARRAY['추천','프리미엄','가성비'])[floor(random()*3+1)::int]
        ),
        'weight_g', floor(random()*5000+100)::int
    ),
    timestamp '2023-06-01' + random() * (timestamp '2025-06-01' - timestamp '2023-06-01')
FROM generate_series(1, 5000) AS n;

-- 상품 변형 (상품당 1~4개)
INSERT INTO product_variants (product_id, sku, name, price, attributes)
SELECT
    p.product_id,
    'SKU-' || p.product_id || '-' || v.n,
    CASE v.n
        WHEN 1 THEN '기본'
        WHEN 2 THEN '옵션A'
        WHEN 3 THEN '옵션B'
        WHEN 4 THEN '옵션C'
    END,
    p.base_price + (v.n - 1) * round((random() * 10000)::numeric, 2),
    jsonb_build_object(
        'color', (ARRAY['블랙','화이트','네이비','레드','그린'])[floor(random()*5+1)::int],
        'size',  (ARRAY['S','M','L','XL','FREE'])[floor(random()*5+1)::int]
    )
FROM products p
CROSS JOIN generate_series(1, 1 + floor(random()*3)::int) AS v(n);

-- 재고
INSERT INTO inventory (variant_id, quantity, reserved)
SELECT
    variant_id,
    floor(random() * 500 + 10)::int,
    floor(random() * 20)::int
FROM product_variants;

-- 주문 50만 건
INSERT INTO orders (user_id, status, total_amount, address_snapshot, created_at)
SELECT
    floor(random() * 100000 + 1)::bigint,
    (ARRAY['pending','paid','shipping','delivered','cancelled','refunded'])[floor(random()*6+1)::int],
    round((random() * 1000000 + 5000)::numeric, 2),
    jsonb_build_object('recipient', 'user' || floor(random()*100000+1)::int, 'address', '서울시 테스트구'),
    timestamp '2024-01-01' + random() * (timestamp '2025-06-01' - timestamp '2024-01-01')
FROM generate_series(1, 500000);

-- 주문 상세 (주문당 1~3개 아이템)
INSERT INTO order_items (order_id, variant_id, quantity, unit_price, subtotal)
SELECT
    o.order_id,
    (SELECT variant_id FROM product_variants ORDER BY random() LIMIT 1),
    floor(random() * 3 + 1)::int AS qty,
    round((random() * 200000 + 5000)::numeric, 2) AS up,
    round((random() * 200000 + 5000)::numeric, 2) * floor(random() * 3 + 1)::int
FROM orders o
CROSS JOIN generate_series(1, 1 + floor(random()*2)::int) AS item(n)
WHERE o.order_id <= 100000;  -- 처음 10만 주문에 대해서만 (속도를 위해)

-- 결제
INSERT INTO payments (order_id, method, amount, status, paid_at, created_at)
SELECT
    order_id,
    (ARRAY['card','bank_transfer','virtual_account'])[floor(random()*3+1)::int],
    total_amount,
    CASE status
        WHEN 'paid' THEN 'completed'
        WHEN 'shipping' THEN 'completed'
        WHEN 'delivered' THEN 'completed'
        WHEN 'cancelled' THEN 'failed'
        WHEN 'refunded' THEN 'refunded'
        ELSE 'pending'
    END,
    CASE WHEN status IN ('paid','shipping','delivered') THEN created_at + interval '10 minutes' ELSE NULL END,
    created_at
FROM orders
WHERE order_id <= 200000;  -- 속도를 위해

-- 배송
INSERT INTO shipments (order_id, carrier, tracking_no, status, shipped_at, delivered_at, created_at)
SELECT
    order_id,
    (ARRAY['CJ대한통운','한진택배','롯데택배','우체국택배'])[floor(random()*4+1)::int],
    'TRK' || lpad(order_id::text, 12, '0'),
    CASE status
        WHEN 'shipping' THEN 'in_transit'
        WHEN 'delivered' THEN 'delivered'
        ELSE 'preparing'
    END,
    CASE WHEN status IN ('shipping','delivered') THEN created_at + interval '1 day' ELSE NULL END,
    CASE WHEN status = 'delivered' THEN created_at + interval '3 days' ELSE NULL END,
    created_at
FROM orders
WHERE status IN ('shipping', 'delivered') AND order_id <= 200000;

-- 쿠폰
INSERT INTO coupons (code, discount_type, discount_value, min_order_amount, max_uses, valid_from, valid_until)
SELECT
    'COUPON' || lpad(n::text, 4, '0'),
    CASE WHEN random() < 0.5 THEN 'percent' ELSE 'fixed' END,
    CASE WHEN random() < 0.5 THEN round((random()*30+5)::numeric, 0) ELSE round((random()*50000+1000)::numeric, 0) END,
    round((random()*50000)::numeric, 0),
    floor(random()*1000+100)::int,
    timestamp '2024-01-01' + random() * interval '365 days',
    timestamp '2025-01-01' + random() * interval '365 days'
FROM generate_series(1, 100) AS n;

-- 리뷰 (delivered 주문에서)
INSERT INTO reviews (product_id, user_id, order_id, rating, title, body, metadata, created_at)
SELECT
    (SELECT product_id FROM products ORDER BY random() LIMIT 1),
    o.user_id,
    o.order_id,
    floor(random()*5+1)::int,
    '리뷰 제목 ' || o.order_id,
    '이 상품은 ' || (ARRAY['매우 좋습니다','괜찮습니다','보통입니다','별로입니다','최악입니다'])[floor(random()*5+1)::int] || '. 배송도 ' || (ARRAY['빨랐습니다','보통이었습니다','느렸습니다'])[floor(random()*3+1)::int],
    jsonb_build_object(
        'verified', true,
        'helpful_count', floor(random()*50)::int,
        'photo_count', floor(random()*5)::int
    ),
    o.created_at + interval '5 days'
FROM orders o
WHERE o.status = 'delivered' AND o.order_id <= 50000 AND random() < 0.3;

-- 이벤트 로그 (100만 행)
INSERT INTO event_logs (user_id, event_type, payload, created_at)
SELECT
    floor(random() * 100000 + 1)::bigint,
    (ARRAY['page_view','product_click','add_to_cart','purchase','search','login','logout'])[floor(random()*7+1)::int],
    jsonb_build_object(
        'page', (ARRAY['/','/products','/cart','/checkout','/mypage'])[floor(random()*5+1)::int],
        'device', (ARRAY['mobile','desktop','tablet'])[floor(random()*3+1)::int],
        'duration_ms', floor(random()*30000)::int
    ),
    timestamp '2024-01-01' + random() * (timestamp '2025-06-01' - timestamp '2024-01-01')
FROM generate_series(1, 1000000);

-- 통계 갱신
ANALYZE;

-- 확인 메시지
DO $$
BEGIN
    RAISE NOTICE '=== 이커머스 테스트 데이터 생성 완료 ===';
    RAISE NOTICE 'users: %',        (SELECT count(*) FROM users);
    RAISE NOTICE 'products: %',     (SELECT count(*) FROM products);
    RAISE NOTICE 'variants: %',     (SELECT count(*) FROM product_variants);
    RAISE NOTICE 'orders: %',       (SELECT count(*) FROM orders);
    RAISE NOTICE 'event_logs: %',   (SELECT count(*) FROM event_logs);
END $$;
