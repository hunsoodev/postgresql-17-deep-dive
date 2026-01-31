# MVCC와 동시성 제어

## 한줄 요약

PostgreSQL은 MVCC(Multi-Version Concurrency Control)를 통해 여러 트랜잭션이 서로 차단하지 않고 동시에 데이터를 읽고 쓸 수 있게 하며, 각 트랜잭션은 "자기만의 스냅샷"을 보게 됩니다.

## 왜 알아야 하는가

### 실무에서 마주하는 문제들

1. **동시 주문 처리 시 재고 꼬임**
   - 두 명의 고객이 동시에 마지막 재고 1개를 주문하려 할 때
   - 동시성 제어 없이는 재고가 -1이 되는 문제 발생

2. **결제 중복 처리**
   - 네트워크 지연으로 결제 버튼을 여러 번 누른 경우
   - 같은 주문에 대해 두 번 결제되는 상황 방지 필요

3. **통계 조회 시 일관성 문제**
   - 매출 통계를 조회하는 중에 새로운 주문이 들어오면?
   - 조회 시작 시점의 일관된 데이터를 봐야 함

4. **데드락으로 인한 트랜잭션 실패**
   - 두 프로세스가 서로의 락을 기다리며 무한 대기
   - 애플리케이션에서 재시도 로직 필요

5. **읽기 성능 저하**
   - 전통적인 락 방식: 쓰기 중이면 읽기도 대기
   - MVCC: 쓰기 중에도 읽기 가능 (성능 향상)

### MVCC가 없다면?

전통적인 2PL(Two-Phase Locking) 방식에서는:
- Reader가 Writer를 차단
- Writer가 Reader를 차단
- 동시성 성능이 크게 저하됨

PostgreSQL의 MVCC는:
- Reader가 Writer를 차단하지 않음
- Writer가 Reader를 차단하지 않음
- 높은 동시성 성능 제공

## 핵심 개념

### 1. MVCC란 무엇인가?

**비유: 각자 자기만의 사진을 보는 것**

MVCC를 이해하기 위한 비유:
- 데이터베이스는 계속 변화하는 풍경
- 각 트랜잭션은 시작 시점의 "사진(스냅샷)"을 가짐
- 다른 사람이 풍경을 바꿔도 내 사진은 변하지 않음
- 트랜잭션이 커밋되면 새로운 풍경이 만들어짐

**기술적 정의:**
- 같은 데이터에 대해 여러 버전을 유지
- 각 트랜잭션은 자신에게 "보여야 할" 버전만 봄
- 버전 판단은 트랜잭션 ID(XID)로 수행

### 2. 트랜잭션 ID (XID)

PostgreSQL의 모든 트랜잭션은 고유한 32비트 정수 ID를 받습니다.

```sql
-- 현재 트랜잭션 ID 확인
SELECT txid_current();
-- 예: 1000

-- 트랜잭션 없이 ID만 확인 (ID 소비 안 함)
SELECT txid_current_if_assigned();
-- NULL (트랜잭션이 아직 ID를 받지 않은 경우)
```

**XID의 특징:**
- 순차적으로 증가 (1, 2, 3, ...)
- 2^32개 사용 후 순환 (wraparound)
- 특수 XID:
  - 0 (InvalidTransactionId): 유효하지 않은 트랜잭션
  - 1 (BootstrapTransactionId): 부트스트랩 트랜잭션
  - 2 (FrozenTransactionId): 동결된 튜플

### 3. 튜플의 xmin과 xmax

모든 튜플(행)은 보이지 않는 시스템 컬럼을 가집니다:

```sql
-- 시스템 컬럼 확인
SELECT
    xmin,           -- 이 튜플을 생성한 트랜잭션 ID
    xmax,           -- 이 튜플을 삭제/수정한 트랜잭션 ID
    cmin,           -- 생성 명령 ID (트랜잭션 내 순서)
    cmax,           -- 삭제 명령 ID
    ctid,           -- 물리적 위치 (페이지번호, 오프셋)
    user_id,
    username
FROM users
WHERE user_id = 1;
```

**예시 출력:**
```
 xmin | xmax | cmin | cmax | ctid  | user_id | username
------+------+------+------+-------+---------+-----------
 1000 |    0 |    0 |    0 | (0,1) |       1 | alice
```

**필드 의미:**
- `xmin = 1000`: 트랜잭션 1000이 이 행을 생성
- `xmax = 0`: 아직 삭제/수정되지 않음
- `ctid = (0,1)`: 페이지 0, 슬롯 1에 위치

### 4. 가시성 판단 규칙

**트랜잭션이 튜플을 볼 수 있는 조건:**

```
튜플이 보이려면:
1. xmin이 커밋되었고
2. xmin < 내 스냅샷 시점
3. AND (
     xmax = 0 (삭제 안 됨)
     OR xmax가 아직 커밋 안 됨
     OR xmax >= 내 스냅샷 시점
     OR xmax = 내 XID (내가 삭제함)
   )
```

**구체적 시나리오:**

트랜잭션 타임라인:
```
시간 →
XID=100: INSERT (user_id=1, name='Alice') → COMMIT
XID=101: 스냅샷 획득
XID=102: UPDATE (name='Bob') → COMMIT
XID=101: SELECT * FROM users WHERE user_id=1
         → 'Alice' 반환 (XID=102는 내 스냅샷 이후)
```

### 5. UPDATE의 실제 동작

PostgreSQL에서 UPDATE는 실제로 DELETE + INSERT입니다:

```sql
-- 초기 상태
INSERT INTO users (user_id, username, email)
VALUES (1, 'alice', 'alice@example.com');
-- xmin=1000, xmax=0

-- UPDATE 실행
BEGIN; -- XID=1001
UPDATE users SET email = 'newalice@example.com' WHERE user_id = 1;
COMMIT;
```

**내부 동작:**
1. 기존 튜플: xmax = 1001로 표시 (삭제 마킹)
2. 새 튜플 생성: xmin = 1001, xmax = 0
3. 두 튜플 모두 테이블 파일에 존재 (Dead Tuple 발생)

```sql
-- UPDATE 후 확인 (pageinspect 확장 필요)
SELECT xmin, xmax, ctid, user_id, email
FROM users WHERE user_id = 1;

-- 결과:
-- xmin=1001, xmax=0, ctid=(0,2), email='newalice@example.com'

-- 실제로는 두 버전이 모두 존재:
-- (0,1): xmin=1000, xmax=1001, email='alice@example.com' (Dead)
-- (0,2): xmin=1001, xmax=0, email='newalice@example.com' (Live)
```

## OS/파일시스템 관점

### 1. PostgreSQL이 OS 파일 락을 사용하지 않는 이유

**OS 파일 락 (flock/fcntl):**
```c
// OS 레벨 락의 한계
flock(fd, LOCK_EX);  // 파일 전체에 락
fcntl(fd, F_SETLK, ...);  // 바이트 범위 락
```

**한계점:**
1. **성능 저하**: 시스템 콜 오버헤드 큼
2. **세밀한 제어 불가**: 행 단위 락 구현 어려움
3. **데드락 감지 불가**: OS는 애플리케이션 수준 데드락 모름
4. **네트워크 파일 시스템 문제**: NFS에서 flock/fcntl 불안정

**PostgreSQL의 In-Memory 락 매니저:**
- 공유 메모리에 락 테이블 유지
- 해시 테이블로 빠른 조회 (O(1))
- 정교한 데드락 감지 알고리즘
- 락 타임아웃, 우선순위 제어 가능

### 2. 데이터 파일과 MVCC

**파일 레벨에서 보는 MVCC:**

```bash
# PostgreSQL 데이터 디렉토리
cd $PGDATA/base/<database_oid>/<table_oid>

# 테이블 파일 확인
ls -lh 16384
# -rw------- 1 postgres postgres 8.0K Jan 31 10:00 16384

# UPDATE 수행 후 파일 크기 증가
# (새 튜플 버전 추가됨)
```

**파일 구조:**
```
[페이지 0][페이지 1][페이지 2]...
각 페이지 = 8KB

페이지 내부:
[페이지 헤더]
[아이템 ID 배열]  ← 튜플 위치 포인터
[빈 공간]
[튜플 데이터]     ← 실제 데이터 (역방향 성장)
```

**MVCC로 인한 파일 증가:**
- UPDATE/DELETE는 기존 튜플을 즉시 삭제하지 않음
- 파일 크기는 계속 증가 (Bloat)
- VACUUM으로 정리 필요

### 3. 공유 메모리 구조

PostgreSQL의 동시성 제어는 공유 메모리에서 관리됩니다:

```
공유 메모리 영역:
┌─────────────────────────────────┐
│ Lock Manager                     │ ← 테이블/행 락 관리
├─────────────────────────────────┤
│ CLOG (Commit Log)               │ ← XID 커밋 상태
├─────────────────────────────────┤
│ Shared Buffer Pool              │ ← 데이터 페이지 캐시
├─────────────────────────────────┤
│ PROC Array                      │ ← 프로세스 정보
└─────────────────────────────────┘
```

**CLOG (Commit Log):**
- 각 XID의 상태 저장 (in-progress, committed, aborted)
- 2비트/트랜잭션 (매우 컴팩트)
- 가시성 판단 시 참조

```sql
-- CLOG 정보 확인 (간접적)
SELECT * FROM pg_stat_activity;
SELECT * FROM pg_locks;
```

## 격리 수준 (Isolation Levels)

SQL 표준은 4가지 격리 수준을 정의하지만, PostgreSQL은 3가지만 구현합니다.

### 1. Read Uncommitted (미구현 → Read Committed)

PostgreSQL은 Read Uncommitted를 지원하지 않고 자동으로 Read Committed로 동작합니다.

**이유:** Dirty Read는 MVCC 철학에 맞지 않음

### 2. Read Committed (기본값)

**특징:**
- 각 쿼리마다 새로운 스냅샷 획득
- 커밋된 데이터만 보임 (Dirty Read 방지)
- Non-repeatable Read 발생 가능

**실습: Non-repeatable Read**

터미널 1:
```sql
-- 세션 1
BEGIN;
SELECT stock_quantity FROM inventory WHERE variant_id = 100;
-- 결과: 10

-- 잠시 대기...
```

터미널 2:
```sql
-- 세션 2
BEGIN;
UPDATE inventory SET stock_quantity = 5 WHERE variant_id = 100;
COMMIT;
```

터미널 1:
```sql
-- 세션 1 (계속)
SELECT stock_quantity FROM inventory WHERE variant_id = 100;
-- 결과: 5 (변경됨! Non-repeatable Read)
COMMIT;
```

**전자상거래 시나리오:**
```sql
-- 주문 처리 중
BEGIN; -- Read Committed

-- 1. 재고 확인
SELECT stock_quantity FROM inventory WHERE variant_id = 100;
-- stock = 10

-- 다른 세션이 재고를 1로 변경하고 COMMIT

-- 2. 주문 생성 (여기서 다시 재고 확인 필요!)
SELECT stock_quantity FROM inventory WHERE variant_id = 100;
-- stock = 1 (변경됨)

-- 10개 주문하려 했으나 이제 불가능
ROLLBACK;
```

### 3. Repeatable Read

**특징:**
- 트랜잭션 시작 시점의 스냅샷 유지
- Non-repeatable Read 방지
- Phantom Read 방지 (PostgreSQL 특수)
- Serialization Failure 발생 가능

**실습: Repeatable Read에서 일관된 읽기**

터미널 1:
```sql
-- 세션 1
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT stock_quantity FROM inventory WHERE variant_id = 100;
-- 결과: 10
```

터미널 2:
```sql
-- 세션 2
UPDATE inventory SET stock_quantity = 5 WHERE variant_id = 100;
COMMIT;
```

터미널 1:
```sql
-- 세션 1 (계속)
SELECT stock_quantity FROM inventory WHERE variant_id = 100;
-- 결과: 10 (여전히 10! 스냅샷 유지)

-- 하지만 UPDATE 시도하면?
UPDATE inventory SET stock_quantity = stock_quantity - 1
WHERE variant_id = 100;
-- ERROR: could not serialize access due to concurrent update
ROLLBACK;
```

**주의사항:**
- UPDATE/DELETE는 최신 버전을 봄 (First Updater Wins)
- 충돌 시 Serialization Failure 발생
- 애플리케이션에서 재시도 필요

### 4. Serializable

**특징:**
- SSI (Serializable Snapshot Isolation) 사용
- 직렬화 가능성 보장 (마치 트랜잭션이 순차 실행된 것처럼)
- Phantom Read 완전 차단
- 성능 오버헤드 존재

**실습: Write Skew 방지**

시나리오: 두 관리자가 동시에 쿠폰 발급 수를 늘리려 함 (총합 제한 있음)

```sql
-- 초기 데이터
CREATE TABLE coupon_limits (
    id INT PRIMARY KEY,
    issued_count INT,
    max_count INT
);
INSERT INTO coupon_limits VALUES (1, 80, 100), (2, 15, 100);
-- 규칙: issued_count 총합 ≤ 150
```

터미널 1:
```sql
-- 세션 1: Read Committed
BEGIN;
SELECT SUM(issued_count) FROM coupon_limits;
-- 결과: 95 (80+15)
-- 30개 더 발급 가능

UPDATE coupon_limits SET issued_count = 110 WHERE id = 1;
-- 대기...
```

터미널 2:
```sql
-- 세션 2: Read Committed
BEGIN;
SELECT SUM(issued_count) FROM coupon_limits;
-- 결과: 95
-- 30개 더 발급 가능

UPDATE coupon_limits SET issued_count = 45 WHERE id = 2;
COMMIT;
```

터미널 1:
```sql
-- 세션 1 (계속)
COMMIT;

-- 최종 결과
SELECT SUM(issued_count) FROM coupon_limits;
-- 155 (110+45) → 제한 위반! (Write Skew)
```

**Serializable로 해결:**

터미널 1:
```sql
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT SUM(issued_count) FROM coupon_limits;
-- 95
UPDATE coupon_limits SET issued_count = 110 WHERE id = 1;
COMMIT; -- 성공
```

터미널 2:
```sql
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT SUM(issued_count) FROM coupon_limits;
-- 95
UPDATE coupon_limits SET issued_count = 45 WHERE id = 2;
COMMIT;
-- ERROR: could not serialize access due to read/write dependencies
```

### 격리 수준 요약표

| 격리 수준 | Dirty Read | Non-repeatable Read | Phantom Read | Serialization Anomaly |
|-----------|------------|---------------------|--------------|----------------------|
| Read Uncommitted | ❌ 불가능(PG) | ⚠️ 가능 | ⚠️ 가능 | ⚠️ 가능 |
| Read Committed | ❌ 불가능 | ⚠️ 가능 | ⚠️ 가능 | ⚠️ 가능 |
| Repeatable Read | ❌ 불가능 | ❌ 불가능 | ❌ 불가능(PG) | ⚠️ 가능 |
| Serializable | ❌ 불가능 | ❌ 불가능 | ❌ 불가능 | ❌ 불가능 |

## 락(Lock)의 종류

### 1. 테이블 레벨 락

**8가지 락 모드:**

```sql
-- 1. ACCESS SHARE (SELECT)
BEGIN;
SELECT * FROM users;
-- 가장 약한 락, SELECT 시 자동 획득

-- 2. ROW SHARE (SELECT FOR UPDATE/SHARE)
SELECT * FROM users WHERE user_id = 1 FOR UPDATE;
-- 행 수준 락 + 테이블 락

-- 3. ROW EXCLUSIVE (INSERT/UPDATE/DELETE)
UPDATE users SET username = 'bob' WHERE user_id = 1;
-- 데이터 변경 시 자동 획득

-- 4. SHARE UPDATE EXCLUSIVE (VACUUM, CREATE INDEX CONCURRENTLY)
VACUUM users;

-- 5. SHARE (CREATE INDEX)
CREATE INDEX idx_users_email ON users(email);

-- 6. SHARE ROW EXCLUSIVE
-- 일부 ALTER TABLE 명령

-- 7. EXCLUSIVE
-- 대부분의 ALTER TABLE

-- 8. ACCESS EXCLUSIVE (DROP, TRUNCATE, VACUUM FULL)
TRUNCATE TABLE users;
-- 가장 강한 락, 모든 접근 차단
COMMIT;
```

**락 호환성 확인:**

```sql
-- 현재 락 상황 보기
SELECT
    locktype,
    relation::regclass,
    mode,
    granted,
    pid
FROM pg_locks
WHERE relation = 'users'::regclass;
```

**실습: 락 대기 상황**

터미널 1:
```sql
BEGIN;
ALTER TABLE users ADD COLUMN middle_name VARCHAR(100);
-- ACCESS EXCLUSIVE 락 획득
-- 커밋하지 않고 대기...
```

터미널 2:
```sql
-- 간단한 SELECT도 대기
SELECT * FROM users WHERE user_id = 1;
-- 대기... (ACCESS EXCLUSIVE와 충돌)
```

터미널 3:
```sql
-- 대기 중인 쿼리 확인
SELECT
    pid,
    usename,
    state,
    query,
    wait_event_type,
    wait_event
FROM pg_stat_activity
WHERE wait_event IS NOT NULL;
```

### 2. 행 레벨 락

**4가지 행 락 모드:**

```sql
-- 1. FOR UPDATE (배타적 락)
BEGIN;
SELECT * FROM inventory
WHERE variant_id = 100
FOR UPDATE;
-- 다른 트랜잭션의 UPDATE/DELETE/FOR UPDATE 차단

-- 2. FOR NO KEY UPDATE
-- PK를 변경하지 않는 UPDATE용
SELECT * FROM users
WHERE user_id = 1
FOR NO KEY UPDATE;

-- 3. FOR SHARE (공유 락)
SELECT * FROM products
WHERE product_id = 50
FOR SHARE;
-- 다른 트랜잭션의 UPDATE/DELETE 차단, 읽기는 허용

-- 4. FOR KEY SHARE
-- FK 참조 무결성 검사용
SELECT * FROM categories
WHERE category_id = 10
FOR KEY SHARE;
COMMIT;
```

**실습: 재고 차감 동시성 제어**

잘못된 방법 (경쟁 조건):
```sql
-- 세션 1, 2 동시 실행
BEGIN;
SELECT stock_quantity FROM inventory WHERE variant_id = 100;
-- 둘 다 10 읽음

UPDATE inventory
SET stock_quantity = 10 - 3  -- 둘 다 7로 설정
WHERE variant_id = 100;
COMMIT;
-- 결과: 6번 차감되어야 하는데 3번만 차감됨
```

올바른 방법 (FOR UPDATE):
```sql
-- 세션 1
BEGIN;
SELECT stock_quantity FROM inventory
WHERE variant_id = 100
FOR UPDATE;
-- stock = 10, 락 획득

UPDATE inventory
SET stock_quantity = stock_quantity - 3
WHERE variant_id = 100;
COMMIT;
-- stock = 7
```

```sql
-- 세션 2 (세션 1이 커밋될 때까지 대기)
BEGIN;
SELECT stock_quantity FROM inventory
WHERE variant_id = 100
FOR UPDATE;
-- 대기... → 세션 1 커밋 후 stock = 7 읽음

UPDATE inventory
SET stock_quantity = stock_quantity - 3
WHERE variant_id = 100;
COMMIT;
-- stock = 4 (정확함)
```

**FOR UPDATE 옵션:**

```sql
-- NOWAIT: 락 대기 없이 즉시 에러
BEGIN;
SELECT * FROM inventory WHERE variant_id = 100 FOR UPDATE NOWAIT;
-- ERROR: could not obtain lock on row in relation "inventory"

-- SKIP LOCKED: 락된 행은 건너뛰기
SELECT * FROM cart_items
WHERE cart_id IN (SELECT cart_id FROM carts WHERE status = 'pending')
FOR UPDATE SKIP LOCKED
LIMIT 10;
-- 작업 큐 구현에 유용
COMMIT;
```

### 3. Advisory Lock (애플리케이션 레벨 락)

PostgreSQL 고유 기능으로, 애플리케이션이 정의한 ID로 락을 걸 수 있습니다.

```sql
-- 세션 레벨 Advisory Lock
SELECT pg_advisory_lock(12345);
-- 키 12345에 대한 배타적 락 획득

-- 다른 세션에서 시도하면 대기
SELECT pg_advisory_lock(12345);
-- 대기...

-- 락 해제
SELECT pg_advisory_unlock(12345);

-- 트랜잭션 레벨 Advisory Lock
BEGIN;
SELECT pg_advisory_xact_lock(12345);
-- 트랜잭션 종료 시 자동 해제
COMMIT;

-- Try 버전 (대기하지 않음)
SELECT pg_try_advisory_lock(12345);
-- true (성공) 또는 false (실패)
```

**실무 활용: 배치 작업 중복 실행 방지**

```sql
-- 일일 통계 배치 (크론으로 실행)
DO $$
BEGIN
    -- Advisory Lock으로 중복 실행 방지
    IF NOT pg_try_advisory_lock(hashtext('daily_stats_job')) THEN
        RAISE NOTICE 'Another instance is running';
        RETURN;
    END IF;

    -- 통계 생성 작업
    INSERT INTO daily_stats (date, total_orders, total_revenue)
    SELECT
        CURRENT_DATE,
        COUNT(*),
        SUM(total_amount)
    FROM orders
    WHERE created_at >= CURRENT_DATE;

    -- 락은 세션 종료 시 자동 해제
END $$;
```

### 4. 데드락 (Deadlock)

**데드락 시나리오:**

터미널 1:
```sql
BEGIN;
UPDATE users SET email = 'alice@new.com' WHERE user_id = 1;
-- users 테이블의 user_id=1 행에 락

-- 잠시 대기...
UPDATE addresses SET city = 'Seoul' WHERE user_id = 2;
-- addresses 테이블의 user_id=2 행에 락 시도 (대기...)
```

터미널 2:
```sql
BEGIN;
UPDATE addresses SET city = 'Busan' WHERE user_id = 2;
-- addresses 테이블의 user_id=2 행에 락

-- 잠시 대기...
UPDATE users SET email = 'bob@new.com' WHERE user_id = 1;
-- users 테이블의 user_id=1 행에 락 시도 (대기...)
-- ERROR: deadlock detected
```

**PostgreSQL의 데드락 감지:**
- 1초마다 데드락 감지 프로세스 실행
- 데드락 발견 시 한 트랜잭션을 희생자로 선택하여 롤백
- 에러 코드: 40P01

**데드락 방지 전략:**

1. **락 순서 통일:**
```sql
-- 항상 같은 순서로 테이블/행 접근
-- 잘못된 예: A→B, B→A (데드락 가능)
-- 올바른 예: 항상 A→B
```

2. **트랜잭션 짧게 유지:**
```sql
-- 나쁜 예
BEGIN;
UPDATE users SET ...;
-- 외부 API 호출 (느림)
-- 사용자 입력 대기
UPDATE orders SET ...;
COMMIT;

-- 좋은 예
BEGIN;
UPDATE users SET ...;
UPDATE orders SET ...;
COMMIT;
-- 외부 작업은 트랜잭션 밖에서
```

3. **LOCK 명시적 획득:**
```sql
BEGIN;
-- 필요한 모든 테이블 락을 먼저 획득
LOCK TABLE users IN ROW EXCLUSIVE MODE;
LOCK TABLE addresses IN ROW EXCLUSIVE MODE;

-- 이후 작업
UPDATE users ...;
UPDATE addresses ...;
COMMIT;
```

## Serializable Snapshot Isolation (SSI)

PostgreSQL의 Serializable 격리 수준은 SSI 기법을 사용합니다.

### SSI 동작 원리

**전통적인 2PL vs SSI:**
- 2PL: 비관적 동시성 제어 (락으로 충돌 방지)
- SSI: 낙관적 동시성 제어 (충돌 감지 후 재시도)

**SSI의 핵심:**
- 트랜잭션 간 읽기/쓰기 의존성 추적
- 직렬화 가능성을 위반하는 패턴 감지
- 위험한 구조(Dangerous Structure) 발견 시 트랜잭션 중단

**위험한 구조 예시:**

```
T1: Read(x) → Write(y)
T2: Read(y) → Write(x)

만약 T1이 T2보다 먼저 커밋되었지만,
T1의 Read(x)가 T2의 Write(x) 이전이고
T2의 Read(y)가 T1의 Write(y) 이전이면
→ 사이클 발생 (직렬화 불가능)
```

**실습: SSI로 이상 현상 방지**

```sql
-- 테이블 준비
CREATE TABLE account (
    account_id INT PRIMARY KEY,
    balance NUMERIC
);
INSERT INTO account VALUES (1, 100), (2, 100);

-- 제약: 모든 계좌 잔액 합 = 200
```

터미널 1:
```sql
BEGIN ISOLATION LEVEL SERIALIZABLE;
-- T1: 계좌 1의 잔액을 읽고 계좌 2로 이체
SELECT balance FROM account WHERE account_id = 1;
-- 100
UPDATE account SET balance = balance - 50 WHERE account_id = 1;
UPDATE account SET balance = balance + 50 WHERE account_id = 2;
-- 잠시 대기...
COMMIT;
```

터미널 2:
```sql
BEGIN ISOLATION LEVEL SERIALIZABLE;
-- T2: 계좌 2의 잔액을 읽고 계좌 1로 이체
SELECT balance FROM account WHERE account_id = 2;
-- 100
UPDATE account SET balance = balance - 30 WHERE account_id = 2;
UPDATE account SET balance = balance + 30 WHERE account_id = 1;
COMMIT;
-- ERROR: could not serialize access due to read/write dependencies
```

**SSI 성능 고려사항:**
- 읽기/쓰기 의존성 추적 오버헤드
- 직렬화 실패 시 재시도 필요
- 짧은 트랜잭션에 유리
- 읽기 전용 트랜잭션은 오버헤드 없음

## PostgreSQL 17의 새로운 기능

### transaction_timeout

PostgreSQL 17부터 트랜잭션 전체에 타임아웃을 설정할 수 있습니다.

```sql
-- 트랜잭션 타임아웃 설정 (밀리초)
SET transaction_timeout = 5000; -- 5초

BEGIN;
-- 장시간 실행되는 작업
SELECT pg_sleep(10);
-- ERROR: terminating connection due to transaction timeout
ROLLBACK;
```

**설정 레벨:**
```sql
-- 세션 레벨
SET transaction_timeout = 60000; -- 60초

-- 데이터베이스 레벨
ALTER DATABASE ecommerce SET transaction_timeout = 30000;

-- 사용자 레벨
ALTER USER app_user SET transaction_timeout = 10000;

-- postgresql.conf
transaction_timeout = 120000 -- 2분
```

**활용 시나리오:**
- 장시간 대기하는 트랜잭션 자동 종료
- 애플리케이션 버그로 커밋 안 한 트랜잭션 방지
- lock_timeout과 조합하여 사용

```sql
-- 조합 예시
SET lock_timeout = 2000;           -- 락 대기 최대 2초
SET statement_timeout = 30000;     -- 쿼리 실행 최대 30초
SET transaction_timeout = 60000;   -- 트랜잭션 전체 최대 60초
```

## 실습 SQL

### 1. MVCC 동작 확인

```sql
-- 테이블 준비
CREATE TABLE mvcc_test (
    id SERIAL PRIMARY KEY,
    value TEXT
);

-- 초기 데이터
INSERT INTO mvcc_test (value) VALUES ('initial');

-- xmin/xmax 확인
SELECT xmin, xmax, cmin, cmax, ctid, id, value
FROM mvcc_test;
-- xmin=1005, xmax=0

-- UPDATE 수행
BEGIN; -- 가정: XID=1006
UPDATE mvcc_test SET value = 'updated' WHERE id = 1;
COMMIT;

-- 다시 확인
SELECT xmin, xmax, cmin, cmax, ctid, id, value
FROM mvcc_test;
-- xmin=1006, xmax=0, ctid=(0,2) ← ctid 변경됨 (새 튜플)
```

### 2. 동시성 시나리오: 재고 관리

```sql
-- 테이블 준비
INSERT INTO product_variants (variant_id, product_id, sku)
VALUES (200, 50, 'SKU-200');

INSERT INTO inventory (variant_id, stock_quantity, reserved_quantity)
VALUES (200, 100, 0);

-- 세션 1: 재고 확인 및 주문
BEGIN ISOLATION LEVEL REPEATABLE READ;

-- 1. 재고 확인
SELECT stock_quantity - reserved_quantity AS available
FROM inventory
WHERE variant_id = 200
FOR UPDATE;
-- available = 100

-- 2. 주문 생성
INSERT INTO orders (user_id, total_amount, status)
VALUES (1, 50000, 'pending')
RETURNING order_id;
-- order_id = 1001

-- 3. 주문 상품 추가
INSERT INTO order_items (order_id, variant_id, quantity, price)
VALUES (1001, 200, 10, 5000);

-- 4. 재고 예약
UPDATE inventory
SET reserved_quantity = reserved_quantity + 10
WHERE variant_id = 200;

COMMIT;

-- 세션 2: 동시 주문 시도
BEGIN ISOLATION LEVEL REPEATABLE READ;

SELECT stock_quantity - reserved_quantity AS available
FROM inventory
WHERE variant_id = 200
FOR UPDATE;
-- 세션 1이 커밋될 때까지 대기...
-- 세션 1 커밋 후: available = 90

-- 20개 주문 시도
INSERT INTO order_items (order_id, variant_id, quantity, price)
VALUES (1002, 200, 20, 5000);

UPDATE inventory
SET reserved_quantity = reserved_quantity + 20
WHERE variant_id = 200;

COMMIT;
```

### 3. 락 모니터링 쿼리

```sql
-- 현재 락 대기 상황
SELECT
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocked_activity.query AS blocked_query,
    blocking_activity.query AS blocking_query,
    blocked_activity.state AS blocked_state,
    blocking_activity.state AS blocking_state
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks
    ON blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
    AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
    AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
    AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;

-- 테이블별 락 현황
SELECT
    relation::regclass AS table_name,
    mode,
    COUNT(*) AS lock_count,
    granted
FROM pg_locks
WHERE relation IS NOT NULL
GROUP BY relation, mode, granted
ORDER BY relation, mode;

-- 장시간 실행 중인 트랜잭션
SELECT
    pid,
    usename,
    state,
    xact_start,
    NOW() - xact_start AS duration,
    query
FROM pg_stat_activity
WHERE state != 'idle'
AND xact_start IS NOT NULL
ORDER BY xact_start;
```

## 직접 확인해보기

### 1. 페이지 내부 확인 (pageinspect)

```sql
-- pageinspect 확장 설치
CREATE EXTENSION IF NOT EXISTS pageinspect;

-- 테이블의 첫 페이지 헤더 확인
SELECT * FROM page_header(get_raw_page('users', 0));
/*
    lsn    | checksum | flags | lower | upper | special | pagesize | version | prune_xid
-----------+----------+-------+-------+-------+---------+----------+---------+-----------
 0/1A2B3C4 |        0 |     0 |    40 |  8064 |    8192 |     8192 |       4 |         0
*/

-- 페이지 내 아이템 확인
SELECT lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_ctid
FROM heap_page_items(get_raw_page('users', 0))
LIMIT 5;
/*
 lp | lp_off | lp_flags | lp_len | t_xmin | t_xmax | t_ctid
----+--------+----------+--------+--------+--------+--------
  1 |   8160 |        1 |     32 |   1000 |      0 | (0,1)
  2 |   8128 |        1 |     32 |   1006 |      0 | (0,2)
  3 |   8096 |        1 |     32 |   1007 |   1010 | (0,3) ← 삭제됨
*/
```

### 2. 트랜잭션 스냅샷 확인

```sql
-- 현재 트랜잭션의 스냅샷 정보
BEGIN;
SELECT txid_current_snapshot();
-- 예: 1000:1005:1000,1002
-- 형식: xmin:xmax:xip_list
-- xmin=1000: 이보다 작은 XID는 모두 완료
-- xmax=1005: 이보다 크거나 같은 XID는 진행 중
-- xip_list: 1000,1002는 진행 중

-- 특정 XID가 보이는지 확인
SELECT txid_visible_in_snapshot(1001, txid_current_snapshot());
-- true 또는 false
COMMIT;
```

### 3. 데드락 강제 발생

```sql
-- 세션 1
BEGIN;
UPDATE users SET username = 'alice_new' WHERE user_id = 1;
-- 5초 대기
SELECT pg_sleep(5);
UPDATE users SET username = 'bob_new' WHERE user_id = 2;

-- 세션 2 (세션 1 시작 후 2초 뒤 시작)
BEGIN;
UPDATE users SET username = 'bob_new2' WHERE user_id = 2;
-- 5초 대기
SELECT pg_sleep(5);
UPDATE users SET username = 'alice_new2' WHERE user_id = 1;
-- ERROR: deadlock detected

-- 데드락 로그 확인
-- postgresql.conf: log_lock_waits = on, deadlock_timeout = 1s
```

## 실무 팁

### 1. 격리 수준 선택 가이드

```sql
-- 일반적인 CRUD: Read Committed (기본값)
BEGIN; -- 또는 BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT * FROM products WHERE product_id = 100;
UPDATE products SET price = 25000 WHERE product_id = 100;
COMMIT;

-- 복잡한 통계/보고서: Repeatable Read
BEGIN ISOLATION LEVEL REPEATABLE READ;
-- 여러 테이블 조인하여 통계 생성
SELECT ...;
COMMIT;

-- 금융 트랜잭션, 재고 관리: Serializable (필요시)
BEGIN ISOLATION LEVEL SERIALIZABLE;
-- 계좌 이체, 재고 차감 등
COMMIT;
```

### 2. 재시도 로직 (애플리케이션)

```python
# Python 예시
import psycopg2
from psycopg2 import errorcodes

def transfer_inventory(from_id, to_id, qty, max_retries=3):
    for attempt in range(max_retries):
        try:
            with conn.cursor() as cur:
                cur.execute("BEGIN ISOLATION LEVEL REPEATABLE READ")

                # 재고 이동
                cur.execute("""
                    UPDATE inventory
                    SET stock_quantity = stock_quantity - %s
                    WHERE variant_id = %s
                """, (qty, from_id))

                cur.execute("""
                    UPDATE inventory
                    SET stock_quantity = stock_quantity + %s
                    WHERE variant_id = %s
                """, (qty, to_id))

                cur.execute("COMMIT")
                return True

        except psycopg2.Error as e:
            conn.rollback()
            # Serialization failure
            if e.pgcode == errorcodes.SERIALIZATION_FAILURE:
                if attempt < max_retries - 1:
                    continue  # 재시도
                else:
                    raise
            else:
                raise  # 다른 에러는 즉시 상위로

    return False
```

### 3. 락 타임아웃 설정

```sql
-- 세션별 설정
SET lock_timeout = '5s';         -- 락 대기 5초 초과 시 에러
SET statement_timeout = '30s';   -- 쿼리 실행 30초 초과 시 에러
SET idle_in_transaction_session_timeout = '10min'; -- 유휴 트랜잭션 10분 후 종료

-- 특정 쿼리만
BEGIN;
SET LOCAL lock_timeout = '2s';
UPDATE inventory SET stock_quantity = stock_quantity - 1 WHERE variant_id = 100;
-- 락 대기 2초 초과 시 에러, 트랜잭션 종료 시 설정 원복
COMMIT;
```

### 4. 대용량 UPDATE의 동시성 고려

```sql
-- 나쁜 예: 한 번에 전체 UPDATE (락 장시간 점유)
UPDATE products SET updated_at = NOW();

-- 좋은 예: 배치 단위 UPDATE
DO $$
DECLARE
    batch_size INT := 1000;
    updated_count INT;
BEGIN
    LOOP
        UPDATE products
        SET updated_at = NOW()
        WHERE product_id IN (
            SELECT product_id
            FROM products
            WHERE updated_at < NOW() - INTERVAL '1 day'
            LIMIT batch_size
        );

        GET DIAGNOSTICS updated_count = ROW_COUNT;
        EXIT WHEN updated_count = 0;

        -- 다른 트랜잭션에게 기회를 줌
        COMMIT;
        PERFORM pg_sleep(0.1);
    END LOOP;
END $$;
```

### 5. pg_stat_activity 활용

```sql
-- 현재 활동 중인 쿼리
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    NOW() - query_start AS runtime,
    query
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY runtime DESC;

-- 유휴 트랜잭션 찾기
SELECT
    pid,
    usename,
    state,
    NOW() - xact_start AS idle_duration,
    query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
AND xact_start < NOW() - INTERVAL '5 minutes';

-- 특정 프로세스 종료 (주의!)
SELECT pg_terminate_backend(12345); -- PID
```

### 6. 프로덕션 체크리스트

```sql
-- 1. 격리 수준 확인
SHOW default_transaction_isolation;

-- 2. 타임아웃 설정 확인
SHOW statement_timeout;
SHOW lock_timeout;
SHOW idle_in_transaction_session_timeout;

-- 3. 로깅 설정 (postgresql.conf)
-- log_lock_waits = on
-- deadlock_timeout = 1s
-- log_min_duration_statement = 1000 (1초 이상 쿼리 로깅)

-- 4. 모니터링 쿼리 정기 실행
-- - 장시간 락 대기
-- - 장시간 실행 트랜잭션
-- - 데드락 발생 빈도
```

## 다이어그램 참조

이 노트와 함께 다음 다이어그램을 참고하세요:
- `diagrams/04-mvcc-visibility.drawio`: MVCC 가시성 판단 흐름도

## 참고 링크

### 공식 문서
- [Chapter 13. Concurrency Control](https://www.postgresql.org/docs/17/mvcc.html)
- [Chapter 13.2. Transaction Isolation](https://www.postgresql.org/docs/17/transaction-iso.html)
- [Chapter 13.3. Explicit Locking](https://www.postgresql.org/docs/17/explicit-locking.html)
- [pg_locks View](https://www.postgresql.org/docs/17/view-pg-locks.html)
- [Release Notes - PostgreSQL 17](https://www.postgresql.org/docs/17/release-17.html)

### 심화 학습
- [SSI in PostgreSQL (Dan R. K. Ports)](https://drkp.net/papers/ssi-vldb12.pdf)
- [MVCC Unmasked (Bruce Momjian)](https://momjian.us/main/writings/pgsql/mvcc.pdf)
- [PostgreSQL Internals (Egor Rogov)](https://postgrespro.com/community/books/internals)

### 블로그 & 튜토리얼
- [Postgres MVCC in Pictures](https://momjian.us/main/blogs/pgblog/2020.html#January_21_2020)
- [Understanding Isolation Levels](https://www.cybertec-postgresql.com/en/transaction-isolation-levels/)
- [Dealing with Deadlocks](https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-DEADLOCKS)

---

**다음 노트:** [05-vacuum-and-maintenance.md](./05-vacuum-and-maintenance.md)
**이전 노트:** [03-query-execution.md](./03-query-execution.md)
**목차로 돌아가기:** [README.md](../README.md)
