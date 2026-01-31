# 보안과 접근 제어

## 한줄 요약
PostgreSQL의 다층 보안 체계(인증, 역할 기반 접근 제어, 행 수준 보안)를 이해하고 올바르게 구성하여 데이터베이스를 무단 접근과 데이터 유출로부터 보호하는 것이 운영 환경에서 필수적입니다.

## 왜 알아야 하는가

### 1. 데이터 보호
- **개인정보 보호**: GDPR, 개인정보보호법 등 법적 요구사항 준수
- **비즈니스 기밀**: 매출, 고객 정보, 거래 내역 등 민감 데이터 보호
- **데이터 무결성**: 권한 없는 수정/삭제 방지

### 2. 규정 준수
- **접근 제어**: 누가, 언제, 무엇에 접근했는지 추적
- **감사 추적**: 모든 접근 기록 유지
- **최소 권한 원칙**: 필요한 권한만 부여

### 3. 보안 사고 예방
- **SQL 인젝션**: 파라미터화된 쿼리로 방지
- **권한 상승**: 역할 계층 구조로 통제
- **데이터 유출**: 행 수준 보안으로 차단

### 4. 다중 테넌트 애플리케이션
- **테넌트 분리**: RLS로 데이터 격리
- **SaaS 환경**: 각 고객의 데이터 분리
- **조직 단위 접근 제어**: 부서별, 팀별 데이터 접근 제한

## 핵심 개념

### 1. Role 시스템

PostgreSQL에서는 사용자(User)와 그룹(Group)을 통합하여 Role(역할)이라고 부릅니다.

#### Role의 종류

**로그인 Role (사용자)**:
```sql
-- 로그인 가능한 사용자 생성
CREATE ROLE app_user WITH LOGIN PASSWORD 'secure_password';

-- 또는 CREATE USER (CREATE ROLE ... WITH LOGIN의 별칭)
CREATE USER app_user WITH PASSWORD 'secure_password';
```

**그룹 Role (권한 그룹)**:
```sql
-- 로그인 불가능한 그룹 Role
CREATE ROLE readonly_group;
CREATE ROLE readwrite_group;
CREATE ROLE admin_group;

-- 그룹에 권한 부여
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_group;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO readwrite_group;

-- 사용자를 그룹에 추가
GRANT readonly_group TO app_user;
```

#### Role 속성

```sql
-- 다양한 Role 속성
CREATE ROLE power_user WITH
    LOGIN                    -- 로그인 가능
    PASSWORD 'secure_pass'   -- 비밀번호
    SUPERUSER                -- 슈퍼유저 권한 (위험!)
    CREATEDB                 -- 데이터베이스 생성 권한
    CREATEROLE               -- Role 생성 권한
    REPLICATION              -- 복제 권한
    CONNECTION LIMIT 10      -- 최대 동시 접속 수
    VALID UNTIL '2025-12-31' -- 만료일
    IN ROLE readonly_group;  -- 그룹 멤버십

-- 속성 변경
ALTER ROLE app_user WITH PASSWORD 'new_password';
ALTER ROLE app_user VALID UNTIL '2026-12-31';
ALTER ROLE app_user CONNECTION LIMIT 5;

-- 슈퍼유저 권한 제거 (보안)
ALTER ROLE power_user WITH NOSUPERUSER;
```

#### Role 확인

```sql
-- 모든 Role 조회
SELECT
    rolname AS role_name,
    rolsuper AS is_superuser,
    rolinherit AS can_inherit,
    rolcreaterole AS can_create_role,
    rolcreatedb AS can_create_db,
    rolcanlogin AS can_login,
    rolreplication AS can_replicate,
    rolconnlimit AS connection_limit,
    rolvaliduntil AS valid_until
FROM pg_roles
ORDER BY rolname;

-- 현재 사용자 확인
SELECT current_user, session_user;

-- Role 멤버십 확인
SELECT
    r.rolname AS role_name,
    m.rolname AS member_of
FROM pg_roles r
JOIN pg_auth_members am ON r.oid = am.member
JOIN pg_roles m ON am.roleid = m.oid
WHERE r.rolname = 'app_user';
```

### 2. GRANT와 REVOKE

#### 테이블 권한

```sql
-- SELECT 권한 부여
GRANT SELECT ON products TO readonly_user;

-- 여러 권한 동시 부여
GRANT SELECT, INSERT, UPDATE ON orders TO app_user;

-- 모든 권한 부여
GRANT ALL PRIVILEGES ON payments TO admin_user;

-- 스키마의 모든 테이블에 권한 부여
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_group;

-- 미래에 생성될 테이블에도 권한 자동 부여
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO readonly_group;

-- 권한 취소
REVOKE INSERT, UPDATE, DELETE ON products FROM app_user;

-- 모든 권한 취소
REVOKE ALL PRIVILEGES ON payments FROM app_user;
```

#### 컬럼 레벨 권한 (PostgreSQL 17)

```sql
-- 특정 컬럼만 SELECT 허용
GRANT SELECT (user_id, username, email) ON users TO app_user;

-- 민감한 컬럼 제외
-- password_hash, ssn 등은 접근 불가
GRANT SELECT (user_id, username, email, created_at) ON users TO support_team;
REVOKE SELECT (password_hash) ON users FROM support_team;
```

#### 함수 및 프로시저 권한

```sql
-- 함수 실행 권한
GRANT EXECUTE ON FUNCTION calculate_order_total(INTEGER) TO app_user;

-- 모든 함수 실행 권한
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_user;

-- 미래 함수에도 권한 부여
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO app_user;
```

#### 스키마 권한

```sql
-- 스키마 사용 권한 (객체에 접근하기 위한 전제조건)
GRANT USAGE ON SCHEMA public TO app_user;

-- 스키마 내 객체 생성 권한
GRANT CREATE ON SCHEMA public TO developer_user;

-- 권한 확인
SELECT
    schemaname,
    has_schema_privilege('app_user', schemaname, 'USAGE') AS can_use,
    has_schema_privilege('app_user', schemaname, 'CREATE') AS can_create
FROM pg_namespace
JOIN pg_catalog.pg_namespace ON pg_namespace.oid = pg_catalog.pg_namespace.oid
WHERE nspname NOT LIKE 'pg_%' AND nspname != 'information_schema';
```

### 3. PostgreSQL 17: MAINTAIN 권한

PostgreSQL 17에서 새롭게 도입된 `MAINTAIN` 권한은 테이블의 유지보수 작업(VACUUM, ANALYZE, REINDEX 등)을 일반 사용자에게 허용합니다.

```sql
-- MAINTAIN 권한 부여 (PostgreSQL 17)
GRANT MAINTAIN ON products TO maintenance_user;

-- MAINTAIN 권한으로 가능한 작업
SET ROLE maintenance_user;

VACUUM products;           -- 가능
ANALYZE products;          -- 가능
REINDEX TABLE products;    -- 가능
CLUSTER products;          -- 가능

-- 하지만 데이터 변경은 불가
-- INSERT INTO products VALUES (...);  -- 에러 (권한 없음)

-- 모든 테이블에 MAINTAIN 권한 부여
GRANT MAINTAIN ON ALL TABLES IN SCHEMA public TO maintenance_user;

-- 미래 테이블에도 적용
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT MAINTAIN ON TABLES TO maintenance_user;
```

**MAINTAIN 권한의 이점**:
- DBA 권한 없이 성능 최적화 작업 가능
- 자동화된 유지보수 스크립트에 최소 권한 부여
- 보안을 유지하면서 운영 효율성 향상

### 4. Row Level Security (RLS)

RLS는 테이블의 특정 행에 대한 접근을 제어합니다. 같은 테이블을 공유하면서도 사용자별로 다른 데이터를 보여줄 수 있습니다.

#### RLS 기본 개념

```sql
-- 1. RLS 활성화
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

-- 2. 정책 생성
-- 사용자는 자신의 주문만 볼 수 있음
CREATE POLICY user_orders_policy ON orders
    FOR SELECT
    TO PUBLIC
    USING (user_id = current_setting('app.current_user_id')::INTEGER);

-- 3. 애플리케이션에서 사용자 ID 설정
SET app.current_user_id = '123';

-- 4. 쿼리 실행
SELECT * FROM orders;  -- user_id = 123인 주문만 반환됨
```

#### RLS 정책 유형

**SELECT 정책**:
```sql
-- 읽기 정책: 사용자는 자신의 데이터만 조회
CREATE POLICY select_own_data ON users
    FOR SELECT
    USING (user_id = current_setting('app.current_user_id')::INTEGER);
```

**INSERT 정책**:
```sql
-- 삽입 정책: user_id는 현재 사용자 ID와 일치해야 함
CREATE POLICY insert_own_data ON orders
    FOR INSERT
    WITH CHECK (user_id = current_setting('app.current_user_id')::INTEGER);
```

**UPDATE 정책**:
```sql
-- 수정 정책: 자신의 데이터만 수정 가능
CREATE POLICY update_own_data ON orders
    FOR UPDATE
    USING (user_id = current_setting('app.current_user_id')::INTEGER)
    WITH CHECK (user_id = current_setting('app.current_user_id')::INTEGER);
```

**DELETE 정책**:
```sql
-- 삭제 정책: 자신의 데이터만 삭제 가능
CREATE POLICY delete_own_data ON orders
    FOR DELETE
    USING (user_id = current_setting('app.current_user_id')::INTEGER);
```

**ALL 정책** (모든 작업에 적용):
```sql
CREATE POLICY all_own_data ON cart_items
    FOR ALL
    USING (
        cart_id IN (
            SELECT cart_id FROM carts
            WHERE user_id = current_setting('app.current_user_id')::INTEGER
        )
    );
```

#### 복잡한 RLS 예시

```sql
-- 다중 테넌트 애플리케이션
CREATE POLICY tenant_isolation ON orders
    FOR ALL
    USING (
        tenant_id = current_setting('app.tenant_id')::INTEGER
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id')::INTEGER
    );

-- 역할 기반 정책
CREATE POLICY admin_full_access ON orders
    FOR ALL
    TO admin_group
    USING (true);  -- 관리자는 모든 행 접근 가능

CREATE POLICY manager_department_access ON orders
    FOR SELECT
    TO manager_group
    USING (
        department_id IN (
            SELECT department_id FROM user_departments
            WHERE user_id = current_setting('app.current_user_id')::INTEGER
        )
    );

-- 시간 기반 정책
CREATE POLICY recent_orders_only ON orders
    FOR SELECT
    USING (
        created_at >= CURRENT_DATE - INTERVAL '90 days'
    );
```

#### RLS 정책 확인

```sql
-- 테이블의 RLS 설정 확인
SELECT
    schemaname,
    tablename,
    rowsecurity AS rls_enabled
FROM pg_tables
WHERE schemaname = 'public';

-- 정책 목록 조회
SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,  -- SELECT, INSERT, UPDATE, DELETE, ALL
    qual,  -- USING 절
    with_check  -- WITH CHECK 절
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;
```

#### RLS 우회 (특권 사용자)

```sql
-- 특정 Role은 RLS 우회 가능
ALTER TABLE orders FORCE ROW LEVEL SECURITY;  -- 소유자도 RLS 적용

-- 또는 특정 Role만 우회
GRANT BYPASSRLS TO admin_user;  -- 모든 RLS 정책 우회
```

## OS/파일시스템 관점

### 1. PGDATA 디렉토리 권한

PostgreSQL 데이터 디렉토리는 **반드시 700 권한**(소유자만 읽기/쓰기/실행)이어야 합니다.

```bash
# 데이터 디렉토리 권한 확인 (Linux/Mac)
$ ls -ld $PGDATA
drwx------ 19 postgres postgres 4096 Jan 31 10:00 /var/lib/postgresql/17/main

# 잘못된 권한 (보안 취약)
$ chmod 755 $PGDATA  # 위험! 다른 사용자가 읽기 가능

# PostgreSQL 시작 시 권한 체크
$ pg_ctl start
FATAL: data directory "/var/lib/postgresql/data" has wrong ownership
DETAIL: The server must be started by the user that owns the data directory.

# 올바른 권한 설정
$ chmod 700 $PGDATA
$ chown -R postgres:postgres $PGDATA
```

**주요 파일/디렉토리 권한**:
```bash
$ ls -l $PGDATA
drwx------ 5 postgres postgres  4096 pg_wal/       # 700
drwx------ 2 postgres postgres  4096 base/         # 700
drwx------ 2 postgres postgres  4096 global/       # 700
-rw------- 1 postgres postgres  4513 pg_hba.conf   # 600
-rw------- 1 postgres postgres 24576 postgresql.conf  # 600
```

### 2. Unix 소켓 vs TCP 보안 차이

#### Unix Domain Socket (로컬 연결)

```bash
# Unix 소켓 파일 위치
$ ls -l /var/run/postgresql/
srwxrwxrwx 1 postgres postgres 0 .s.PGSQL.5432  # 소켓 파일

# Unix 소켓 연결 (로컬 전용)
$ psql -h /var/run/postgresql -U postgres
```

**Unix 소켓 보안 특징**:
- **OS 레벨 인증**: 파일 시스템 권한 사용
- **peer 인증**: Unix 사용자명과 PostgreSQL Role 매칭
- **빠름**: TCP 오버헤드 없음
- **로컬 전용**: 네트워크 노출 없음

```conf
# pg_hba.conf - Unix 소켓 peer 인증
local   all   postgres   peer
local   all   all        peer
```

#### TCP/IP 연결 (네트워크)

```bash
# TCP 연결
$ psql -h localhost -p 5432 -U app_user
```

**TCP 보안 고려사항**:
- **네트워크 노출**: 방화벽 필요
- **암호화**: SSL/TLS 사용 권장
- **비밀번호 인증**: scram-sha-256 사용
- **IP 필터링**: pg_hba.conf에서 허용 IP 제한

```conf
# pg_hba.conf - TCP 연결 설정
# TYPE  DATABASE  USER         ADDRESS          METHOD
host    all       app_user     192.168.1.0/24   scram-sha-256
hostssl all       all          0.0.0.0/0        scram-sha-256  # SSL 필수
```

### 3. SSL/TLS 암호화

```conf
# postgresql.conf - SSL 활성화
ssl = on
ssl_cert_file = '/etc/postgresql/server.crt'
ssl_key_file = '/etc/postgresql/server.key'
ssl_ca_file = '/etc/postgresql/root.crt'

# SSL 암호화 알고리즘 설정 (PostgreSQL 17)
ssl_min_protocol_version = 'TLSv1.3'
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL'
```

```bash
# SSL 인증서 생성 (개발용)
$ openssl req -new -x509 -days 365 -nodes -text \
    -out server.crt -keyout server.key

# 파일 권한 설정
$ chmod 600 server.key
$ chown postgres:postgres server.key server.crt
```

**클라이언트 연결**:
```bash
# SSL 필수 연결
$ psql "host=db.example.com sslmode=require user=app_user"

# SSL 인증서 검증
$ psql "host=db.example.com sslmode=verify-full sslrootcert=/path/to/root.crt"
```

## pg_hba.conf 인증 설정

`pg_hba.conf` (Host-Based Authentication)는 클라이언트 인증 규칙을 정의합니다.

### pg_hba.conf 구조

```conf
# TYPE  DATABASE  USER         ADDRESS          METHOD  [OPTIONS]

# 로컬 연결 (Unix 소켓)
local   all       postgres                      peer

# 로컬 TCP 연결
host    all       all          127.0.0.1/32     scram-sha-256
host    all       all          ::1/128          scram-sha-256

# 사설 네트워크
host    all       app_user     192.168.1.0/24   scram-sha-256

# 특정 데이터베이스
host    ecommerce app_user     10.0.0.0/8       scram-sha-256

# SSL 필수
hostssl all       all          0.0.0.0/0        scram-sha-256

# SSL 금지 (평문 통신)
hostnossl all     all          192.168.1.0/24   scram-sha-256

# 인증 거부
host    all       all          0.0.0.0/0        reject
```

### 인증 방법

**trust** (비밀번호 없음, 위험!):
```conf
local   all   all   trust  # 로컬 연결은 무조건 허용
```

**peer** (Unix 사용자명 매칭):
```conf
local   all   postgres   peer
# Unix 사용자 'postgres'만 PostgreSQL role 'postgres'로 연결 가능
```

**scram-sha-256** (권장):
```conf
host   all   all   0.0.0.0/0   scram-sha-256
# 암호화된 비밀번호 인증
```

**md5** (구식, 비권장):
```conf
host   all   all   0.0.0.0/0   md5
# MD5 해시 (SHA-256보다 약함)
```

**cert** (클라이언트 인증서):
```conf
hostssl   all   all   0.0.0.0/0   cert
# SSL 클라이언트 인증서로 인증
```

**ldap** (LDAP 서버):
```conf
host   all   all   0.0.0.0/0   ldap ldapserver=ldap.example.com ldapbasedn="dc=example,dc=com"
```

**radius** (RADIUS 서버):
```conf
host   all   all   0.0.0.0/0   radius radiusservers="radius1.example.com,radius2.example.com" radiussecret="secret"
```

### pg_hba.conf 적용

```bash
# 설정 파일 위치 확인
$ psql -c "SHOW hba_file"
           hba_file
-------------------------------
 /etc/postgresql/17/main/pg_hba.conf

# 설정 변경 후 리로드 (재시작 불필요)
$ pg_ctl reload
# 또는
$ psql -c "SELECT pg_reload_conf()"
```

### pg_hba.conf 디버깅

```sql
-- 현재 적용된 규칙 확인
SELECT * FROM pg_hba_file_rules;

-- 연결 실패 로그 확인
SHOW log_connections;
SHOW log_disconnections;
```

## PostgreSQL 17: sslnegotiation=direct

PostgreSQL 17에서는 SSL 협상 방식을 제어하는 `sslnegotiation` 파라미터가 추가되었습니다.

### 기존 SSL 협상 (PostgreSQL 16 이하)

```
클라이언트 → 서버: 평문 연결 요청
서버 → 클라이언트: SSL 지원 여부 응답
클라이언트 → 서버: SSL 협상 시작
→ 1.5 RTT (Round Trip Time)
```

### PostgreSQL 17: Direct SSL 협상

```conf
# pg_hba.conf
hostssl all all 0.0.0.0/0 scram-sha-256 sslnegotiation=direct
```

```
클라이언트 → 서버: 즉시 SSL 핸드셰이크
→ 1 RTT (더 빠름)
```

**장점**:
- **성능 향상**: 연결 시간 단축
- **보안 강화**: 평문 단계 제거
- **프록시 호환**: HAProxy, nginx 등과 더 잘 작동

**사용 예시**:
```bash
# 클라이언트 연결
$ psql "host=db.example.com sslmode=require sslnegotiation=direct"
```

## 실습 SQL

### 실습 1: 역할 기반 접근 제어 전체 과정

```sql
-- ========================================
-- 1단계: 역할 생성
-- ========================================

-- 그룹 역할 생성
CREATE ROLE readonly_group;
CREATE ROLE readwrite_group;
CREATE ROLE admin_group;
CREATE ROLE customer_service_group;
CREATE ROLE data_analyst_group;

-- 사용자 역할 생성
CREATE ROLE app_backend WITH LOGIN PASSWORD 'backend_secure_pass';
CREATE ROLE app_frontend WITH LOGIN PASSWORD 'frontend_secure_pass';
CREATE ROLE analyst_user WITH LOGIN PASSWORD 'analyst_pass';
CREATE ROLE cs_agent WITH LOGIN PASSWORD 'cs_agent_pass';
CREATE ROLE admin_user WITH LOGIN PASSWORD 'admin_secure_pass';

-- ========================================
-- 2단계: 그룹에 권한 부여
-- ========================================

-- readonly_group: 모든 테이블 읽기 전용
GRANT CONNECT ON DATABASE ecommerce TO readonly_group;
GRANT USAGE ON SCHEMA public TO readonly_group;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_group;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO readonly_group;

-- readwrite_group: 읽기/쓰기 권한
GRANT CONNECT ON DATABASE ecommerce TO readwrite_group;
GRANT USAGE ON SCHEMA public TO readwrite_group;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO readwrite_group;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO readwrite_group;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO readwrite_group;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO readwrite_group;

-- admin_group: 모든 권한
GRANT ALL PRIVILEGES ON DATABASE ecommerce TO admin_group;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO admin_group;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO admin_group;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO admin_group;

-- customer_service_group: 고객 지원용 권한
GRANT CONNECT ON DATABASE ecommerce TO customer_service_group;
GRANT USAGE ON SCHEMA public TO customer_service_group;
GRANT SELECT ON users, orders, order_items, shipments TO customer_service_group;
GRANT UPDATE (status) ON orders TO customer_service_group;
GRANT UPDATE (tracking_number, status) ON shipments TO customer_service_group;

-- data_analyst_group: 분석용 읽기 전용 + 집계
GRANT CONNECT ON DATABASE ecommerce TO data_analyst_group;
GRANT USAGE ON SCHEMA public TO data_analyst_group;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO data_analyst_group;
GRANT EXECUTE ON FUNCTION get_sales_report(DATE, DATE) TO data_analyst_group;

-- ========================================
-- 3단계: 사용자를 그룹에 추가
-- ========================================

GRANT readwrite_group TO app_backend;
GRANT readonly_group TO app_frontend;
GRANT data_analyst_group TO analyst_user;
GRANT customer_service_group TO cs_agent;
GRANT admin_group TO admin_user;

-- ========================================
-- 4단계: 특수 권한 설정
-- ========================================

-- 백엔드는 함수 실행 가능
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_backend;

-- 프론트엔드는 특정 함수만 실행 가능
GRANT EXECUTE ON FUNCTION get_product_list() TO app_frontend;
GRANT EXECUTE ON FUNCTION search_products(TEXT) TO app_frontend;

-- 민감한 컬럼 접근 제한
REVOKE SELECT (password_hash) ON users FROM customer_service_group;
REVOKE SELECT (ssn, tax_id) ON users FROM customer_service_group;

-- PostgreSQL 17: 유지보수 권한
CREATE ROLE maintenance_user WITH LOGIN PASSWORD 'maint_pass';
GRANT MAINTAIN ON ALL TABLES IN SCHEMA public TO maintenance_user;

-- ========================================
-- 5단계: 권한 확인
-- ========================================

-- 특정 사용자의 테이블 권한 확인
SELECT
    grantee,
    table_schema,
    table_name,
    privilege_type
FROM information_schema.table_privileges
WHERE grantee = 'app_backend'
ORDER BY table_name, privilege_type;

-- Role 멤버십 확인
SELECT
    r.rolname AS role,
    ARRAY_AGG(m.rolname) AS member_of
FROM pg_roles r
LEFT JOIN pg_auth_members am ON r.oid = am.member
LEFT JOIN pg_roles m ON am.roleid = m.oid
WHERE r.rolname IN ('app_backend', 'app_frontend', 'analyst_user', 'cs_agent', 'admin_user')
GROUP BY r.rolname;
```

### 실습 2: Row Level Security (RLS) 전체 과정

```sql
-- ========================================
-- 1단계: 테스트 환경 준비
-- ========================================

-- 멀티 테넌트 데이터 시뮬레이션
ALTER TABLE users ADD COLUMN tenant_id INTEGER;
ALTER TABLE orders ADD COLUMN tenant_id INTEGER;
ALTER TABLE products ADD COLUMN tenant_id INTEGER;

-- 테넌트 데이터 업데이트 (기존 데이터에 tenant_id 할당)
UPDATE users SET tenant_id = 1 WHERE user_id BETWEEN 1 AND 100;
UPDATE users SET tenant_id = 2 WHERE user_id BETWEEN 101 AND 200;
UPDATE users SET tenant_id = 3 WHERE user_id BETWEEN 201 AND 300;

UPDATE orders SET tenant_id = (SELECT tenant_id FROM users WHERE users.user_id = orders.user_id);
UPDATE products SET tenant_id = 1;  -- 테넌트 1만 상품 보유

-- ========================================
-- 2단계: RLS 활성화
-- ========================================

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE products ENABLE ROW LEVEL SECURITY;

-- ========================================
-- 3단계: 테넌트 격리 정책
-- ========================================

-- users 테이블: 테넌트별 격리
CREATE POLICY tenant_isolation_users ON users
    FOR ALL
    USING (tenant_id = current_setting('app.tenant_id', true)::INTEGER)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::INTEGER);

-- orders 테이블: 테넌트별 격리
CREATE POLICY tenant_isolation_orders ON orders
    FOR ALL
    USING (tenant_id = current_setting('app.tenant_id', true)::INTEGER)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::INTEGER);

-- products 테이블: 테넌트별 격리
CREATE POLICY tenant_isolation_products ON products
    FOR ALL
    USING (tenant_id = current_setting('app.tenant_id', true)::INTEGER)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::INTEGER);

-- ========================================
-- 4단계: 사용자별 데이터 접근 정책
-- ========================================

-- 사용자는 자신의 주문만 조회 가능
CREATE POLICY user_own_orders ON orders
    FOR SELECT
    TO app_frontend
    USING (
        user_id = current_setting('app.current_user_id', true)::INTEGER
        AND tenant_id = current_setting('app.tenant_id', true)::INTEGER
    );

-- 사용자는 자신의 장바구니만 수정 가능
CREATE POLICY user_own_cart ON cart_items
    FOR ALL
    TO app_frontend
    USING (
        cart_id IN (
            SELECT cart_id FROM carts
            WHERE user_id = current_setting('app.current_user_id', true)::INTEGER
        )
    );

-- ========================================
-- 5단계: 역할별 정책
-- ========================================

-- 관리자는 모든 데이터 접근 가능
CREATE POLICY admin_full_access_users ON users
    FOR ALL
    TO admin_group
    USING (true)
    WITH CHECK (true);

CREATE POLICY admin_full_access_orders ON orders
    FOR ALL
    TO admin_group
    USING (true)
    WITH CHECK (true);

-- 고객 서비스는 같은 테넌트의 데이터만 조회 가능
CREATE POLICY cs_read_users ON users
    FOR SELECT
    TO customer_service_group
    USING (tenant_id = current_setting('app.tenant_id', true)::INTEGER);

CREATE POLICY cs_read_orders ON orders
    FOR SELECT
    TO customer_service_group
    USING (tenant_id = current_setting('app.tenant_id', true)::INTEGER);

-- ========================================
-- 6단계: 테스트
-- ========================================

-- 테넌트 1 사용자로 설정
SET app.tenant_id = '1';
SET app.current_user_id = '5';

-- 테넌트 1의 데이터만 보임
SELECT COUNT(*) FROM users;
-- 결과: 100 (tenant_id = 1인 사용자만)

-- 다른 테넌트의 데이터는 보이지 않음
SET app.tenant_id = '2';
SELECT COUNT(*) FROM users;
-- 결과: 100 (tenant_id = 2인 사용자만)

-- 사용자 자신의 주문만 조회
SET ROLE app_frontend;
SET app.tenant_id = '1';
SET app.current_user_id = '5';

SELECT * FROM orders;
-- user_id = 5이고 tenant_id = 1인 주문만 반환

-- 관리자는 모든 데이터 조회 가능
SET ROLE admin_user;
SELECT COUNT(*) FROM users;
-- 결과: 300 (모든 테넌트)

-- ========================================
-- 7단계: RLS 우회 설정 (필요 시)
-- ========================================

-- 백엔드 애플리케이션은 RLS 우회 (테넌트 설정으로 제어)
GRANT BYPASSRLS TO app_backend;

-- ========================================
-- 8단계: 정책 확인 및 모니터링
-- ========================================

-- 활성화된 RLS 테이블 목록
SELECT
    schemaname,
    tablename,
    rowsecurity AS rls_enabled
FROM pg_tables
WHERE schemaname = 'public' AND rowsecurity = true;

-- 정책 목록
SELECT
    schemaname,
    tablename,
    policyname,
    roles,
    cmd,
    qual AS using_expression,
    with_check AS with_check_expression
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;

-- 특정 사용자의 효과적인 정책 확인
-- (현재 세션의 설정으로 어떤 행이 보이는지 테스트)
SET app.tenant_id = '1';
SET app.current_user_id = '5';

EXPLAIN (VERBOSE) SELECT * FROM orders;
-- Filter 절에 RLS 정책이 적용된 것을 확인
```

### 실습 3: 감사 추적 (Audit Trail)

```sql
-- ========================================
-- 감사 로그 테이블
-- ========================================

CREATE TABLE audit_access_log (
    log_id BIGSERIAL PRIMARY KEY,
    session_user TEXT NOT NULL,
    current_user TEXT NOT NULL,
    client_addr INET,
    application_name TEXT,
    query_text TEXT,
    accessed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 접근 로그 함수
CREATE OR REPLACE FUNCTION log_access()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO audit_access_log (
        session_user,
        current_user,
        client_addr,
        application_name,
        query_text
    ) VALUES (
        SESSION_USER,
        CURRENT_USER,
        inet_client_addr(),
        current_setting('application_name', true),
        current_query()
    );

    RETURN NULL;
END;
$$;

-- 민감한 테이블에 감사 트리거 적용
CREATE TRIGGER audit_users_access
    AFTER SELECT ON users
    FOR EACH STATEMENT
    EXECUTE FUNCTION log_access();

CREATE TRIGGER audit_payments_access
    AFTER SELECT ON payments
    FOR EACH STATEMENT
    EXECUTE FUNCTION log_access();

-- 접근 로그 확인
SELECT
    session_user,
    current_user,
    client_addr,
    application_name,
    LEFT(query_text, 100) AS query_preview,
    accessed_at
FROM audit_access_log
ORDER BY accessed_at DESC
LIMIT 20;
```

## 직접 확인해보기

### 1. 현재 사용자 및 권한 확인

```sql
-- 현재 사용자
SELECT current_user, session_user;

-- 현재 사용자의 Role 속성
SELECT * FROM pg_roles WHERE rolname = current_user;

-- 현재 사용자의 그룹 멤버십
SELECT
    r.rolname AS role_name,
    m.rolname AS member_of,
    a.admin_option
FROM pg_roles r
JOIN pg_auth_members a ON r.oid = a.member
JOIN pg_roles m ON a.roleid = m.oid
WHERE r.rolname = current_user;
```

### 2. 테이블 권한 확인

```sql
-- 특정 테이블에 대한 권한
SELECT
    grantee,
    privilege_type,
    is_grantable
FROM information_schema.table_privileges
WHERE table_name = 'orders'
ORDER BY grantee, privilege_type;

-- 현재 사용자가 특정 테이블에 가진 권한
SELECT
    has_table_privilege(current_user, 'orders', 'SELECT') AS can_select,
    has_table_privilege(current_user, 'orders', 'INSERT') AS can_insert,
    has_table_privilege(current_user, 'orders', 'UPDATE') AS can_update,
    has_table_privilege(current_user, 'orders', 'DELETE') AS can_delete;
```

### 3. RLS 정책 효과 테스트

```sql
-- RLS 정책 적용 전후 비교
-- 1. RLS 비활성화
ALTER TABLE orders DISABLE ROW LEVEL SECURITY;
SELECT COUNT(*) FROM orders;  -- 모든 행

-- 2. RLS 활성화
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
SET app.tenant_id = '1';
SELECT COUNT(*) FROM orders;  -- 정책에 의해 필터링된 행

-- 3. 실행 계획 확인
EXPLAIN (VERBOSE) SELECT * FROM orders;
-- Filter 절에 RLS 정책이 포함됨
```

### 4. 연결 정보 확인

```sql
-- 현재 활성 연결
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    backend_start,
    state,
    query
FROM pg_stat_activity
WHERE datname = current_database()
ORDER BY backend_start;

-- 연결 통계
SELECT
    usename,
    COUNT(*) AS connection_count,
    MAX(backend_start) AS last_connection
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY usename;
```

## 실무 팁

### 1. 최소 권한 원칙

```sql
-- 나쁜 예: 과도한 권한
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO app_user;

-- 좋은 예: 필요한 권한만 부여
GRANT SELECT, INSERT, UPDATE ON orders, order_items TO app_user;
GRANT SELECT ON products, categories TO app_user;
GRANT EXECUTE ON FUNCTION create_order(INTEGER, JSONB) TO app_user;
```

### 2. Role 계층 구조 활용

```sql
-- 계층 구조
-- superadmin (모든 권한)
--   ├── admin_group (DB 관리)
--   ├── readwrite_group (읽기/쓰기)
--   │   ├── app_backend
--   │   └── app_api
--   └── readonly_group (읽기만)
--       ├── app_frontend
--       └── data_analyst

CREATE ROLE superadmin WITH SUPERUSER;
CREATE ROLE admin_group;
CREATE ROLE readwrite_group;
CREATE ROLE readonly_group;

GRANT readonly_group TO readwrite_group;  -- readwrite는 readonly 권한 포함
GRANT readwrite_group TO admin_group;     -- admin은 readwrite 권한 포함
```

### 3. 비밀번호 정책

```sql
-- 비밀번호 만료 설정
ALTER ROLE app_user VALID UNTIL '2025-12-31';

-- 비밀번호 복잡도 강제 (PostgreSQL 확장)
CREATE EXTENSION IF NOT EXISTS passwordcheck;

-- 비밀번호 변경 주기 알림
SELECT
    rolname,
    rolvaliduntil,
    CASE
        WHEN rolvaliduntil < CURRENT_DATE + INTERVAL '30 days' THEN 'Expiring soon'
        WHEN rolvaliduntil < CURRENT_DATE THEN 'Expired'
        ELSE 'Valid'
    END AS status
FROM pg_roles
WHERE rolcanlogin = true
ORDER BY rolvaliduntil;
```

### 4. 감사 로깅 활성화

```conf
# postgresql.conf

# 연결/종료 로깅
log_connections = on
log_disconnections = on

# 모든 SQL 로깅 (성능 영향 있음, 프로덕션에서는 선택적 사용)
log_statement = 'all'  # none, ddl, mod, all

# 느린 쿼리만 로깅
log_min_duration_statement = 1000  # 1초 이상 걸리는 쿼리

# 에러 로깅
log_line_prefix = '%t [%p]: user=%u,db=%d,app=%a,client=%h '
```

### 5. RLS 성능 최적화

```sql
-- RLS 정책에 인덱스 활용
CREATE INDEX idx_orders_tenant_user ON orders (tenant_id, user_id);

-- RLS 정책이 인덱스를 사용하도록 작성
CREATE POLICY tenant_user_orders ON orders
    FOR SELECT
    USING (
        tenant_id = current_setting('app.tenant_id')::INTEGER
        AND user_id = current_setting('app.current_user_id')::INTEGER
    );

-- 실행 계획 확인
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE order_id = 123;
-- Index Scan using idx_orders_tenant_user 확인
```

### 6. 보안 체크리스트

```sql
-- 보안 점검 쿼리
-- 1. 슈퍼유저 확인
SELECT rolname FROM pg_roles WHERE rolsuper = true;

-- 2. 비밀번호 없는 계정
SELECT rolname FROM pg_roles
WHERE rolcanlogin = true AND rolpassword IS NULL;

-- 3. 만료된 계정
SELECT rolname, rolvaliduntil FROM pg_roles
WHERE rolvaliduntil < CURRENT_DATE;

-- 4. TRUST 인증 사용 확인
SELECT * FROM pg_hba_file_rules WHERE auth_method = 'trust';

-- 5. PUBLIC 권한 확인
SELECT
    tablename,
    has_table_privilege('PUBLIC', schemaname||'.'||tablename, 'SELECT') AS public_select,
    has_table_privilege('PUBLIC', schemaname||'.'||tablename, 'INSERT') AS public_insert
FROM pg_tables
WHERE schemaname = 'public';
```

## 참고 링크

### 공식 PostgreSQL 17 문서
- [Chapter 20: Client Authentication](https://www.postgresql.org/docs/17/client-authentication.html)
- [Chapter 20.1: The pg_hba.conf File](https://www.postgresql.org/docs/17/auth-pg-hba-conf.html)
- [Chapter 21: Database Roles](https://www.postgresql.org/docs/17/user-manag.html)
- [Chapter 21.3: Role Attributes](https://www.postgresql.org/docs/17/role-attributes.html)
- [Chapter 21.6: Function Security](https://www.postgresql.org/docs/17/ddl-priv.html)
- [Chapter 5.8: Row Security Policies](https://www.postgresql.org/docs/17/ddl-rowsecurity.html)
- [Chapter 18.4: SSL/TLS Configuration](https://www.postgresql.org/docs/17/ssl-tcp.html)

### PostgreSQL 17 새 기능
- [PostgreSQL 17 Release Notes - Security](https://www.postgresql.org/docs/17/release-17.html)
- MAINTAIN Privilege
- sslnegotiation=direct
- Enhanced RLS Performance

### 보안 가이드
- [PostgreSQL Security Best Practices](https://www.postgresql.org/docs/17/security.html)
- [Secure TCP/IP Connections with SSL](https://www.postgresql.org/docs/17/ssl-tcp.html)
- [Row Security Policies](https://www.postgresql.org/docs/17/ddl-rowsecurity.html)

### 추가 학습 자료
- PostgreSQL Security Wiki
- OWASP Database Security Guide
- PostgreSQL Authentication Methods Comparison
