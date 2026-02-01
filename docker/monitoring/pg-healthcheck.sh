#!/usr/bin/env bash
# =============================================================================
# pg-healthcheck.sh — PostgreSQL 핵심 지표 모니터링 + Discord 알림
# =============================================================================
#
# [파일 역할]
#   PostgreSQL의 건강 상태를 8가지 관점에서 점검하고, 이상이 발견되면
#   Discord로 경고/위험 알림을 보내는 스크립트.
#   cron에 등록하여 5분마다 자동 실행한다.
#
# [전체 데이터 흐름]
#   1. discord-webhook.sh를 source로 로드 → .env에서 DB/Discord 설정 읽기
#   2. pg_isready로 DB 생존 확인
#   3. psql로 8가지 SQL 쿼리 실행 → 각 결과를 변수에 저장
#   4. 임계값과 비교 → 초과 시 alerts 문자열에 메시지 누적
#   5. alerts가 비어있으면 → 콘솔에 "OK" 출력하고 종료 (Discord 알림 없음)
#      alerts가 있으면 → 가장 높은 심각도에 맞는 색상으로 Discord 전송
#
# [cron 등록 예시]
#   */5 * * * * /path/to/pg-healthcheck.sh >> /var/log/pg-healthcheck.log 2>&1
#   ↑ 5분마다                               ↑ stdout을 로그 파일에 추가(append)
#                                            ↑ 2>&1: stderr도 같은 파일로 보냄
#
# =============================================================================

# -----------------------------------------------------------------------------
# set 옵션: 스크립트의 안전장치를 설정한다.
#
#   -e (errexit)  → 명령어가 실패하면(exit code != 0) 즉시 스크립트 중단
#                   실수로 에러를 무시하고 계속 실행하는 것을 방지
#   -u (nounset)  → 정의되지 않은 변수를 사용하면 에러 발생
#                   오타로 $PSQL을 $PSL로 쓰면 빈 문자열 대신 에러가 난다
#   -o pipefail   → 파이프(|) 체인에서 중간 명령이 실패해도 감지
#                   예: 실패하는명령 | grep "패턴" → pipefail 없으면 grep 성공으로 처리됨
#
# 프로덕션 스크립트에서는 이 세 가지를 항상 넣는 것이 좋다.
# -----------------------------------------------------------------------------
set -euo pipefail

# -----------------------------------------------------------------------------
# SCRIPT_DIR: 이 파일이 위치한 디렉토리의 절대 경로
# (discord-webhook.sh에서 상세 설명 참고)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# source: 다른 스크립트 파일의 내용을 현재 쉘 환경에 "포함"한다.
#   → discord-webhook.sh 안의 변수(COLOR_GREEN 등)와 함수(send_discord 등)를
#     이 스크립트에서 직접 사용할 수 있게 된다.
#   → '.' 명령어와 동일하다: . "$SCRIPT_DIR/discord-webhook.sh"
#
# source 실행 시 일어나는 일:
#   1. discord-webhook.sh 안의 .env 로드 코드 실행 → 환경변수 세팅
#   2. COLOR_GREEN, COLOR_YELLOW, COLOR_RED 변수 정의
#   3. send_discord(), json_escape() 함수 정의
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/discord-webhook.sh"

# -----------------------------------------------------------------------------
# PSQL: psql 명령어 + 옵션을 변수에 저장해두고 반복 사용한다.
#
# psql 옵션 설명:
#   -h ${PG_HOST:-localhost}  → 접속할 호스트. ${변수:-기본값} 문법으로
#                                PG_HOST가 비어있으면 localhost를 사용
#   -p ${PG_PORT:-5432}       → 접속 포트 (기본값 5432)
#   -U ${PG_USER:-labuser}    → 접속 유저
#   -d ${PG_DB:-ecommerce}    → 접속 데이터베이스
#   -t                        → 튜플만 출력 (컬럼 헤더, 행 수 요약 제거)
#                                예: 헤더 없이 "42.5" 만 출력
#   -A                        → 정렬 안 함 (공백 패딩 제거)
#                                -t -A 조합이면 순수 값만 나온다
#
# 사용 시: $PSQL -c "SELECT ..." 형태로 쿼리를 실행한다.
# 따옴표 없이 $PSQL로 쓰면 공백 기준으로 분리되어 각 옵션이 개별 인자가 된다.
# -----------------------------------------------------------------------------
PSQL="psql -h ${PG_HOST:-localhost} -p ${PG_PORT:-5432} -U ${PG_USER:-labuser} -d ${PG_DB:-ecommerce} -t -A"

# -----------------------------------------------------------------------------
# alerts: 발견된 문제들을 하나의 문자열에 누적한다.
#         각 체크에서 이상 발견 시 alerts+="메시지\n" 로 추가(append).
#         마지막에 이 문자열이 비어있으면 → 정상, 내용이 있으면 → Discord 전송.
#
# severity: 현재까지 발견된 가장 높은 심각도를 추적한다.
#           green(정상) → yellow(경고) → red(위험) 순서로 올라간다.
# -----------------------------------------------------------------------------
alerts=""
severity="green"

# =============================================================================
# escalate() — 심각도를 올리는 헬퍼 함수
# =============================================================================
#
# [동작 원리]
#   severity는 "가장 높은 레벨"만 유지한다.
#   - red를 받으면 → 무조건 red로 (가장 높음)
#   - yellow을 받으면 → 현재가 red가 아닐 때만 yellow로
#   - green을 받으면 → 아무것도 안 함 (이 함수를 호출할 일이 없음)
#
#   이렇게 하면 여러 체크를 순서대로 돌린 뒤, 마지막에 severity 하나만 보고
#   Discord 알림의 색상(빨강/노랑)을 결정할 수 있다.
#
escalate() {
    local level="$1"   # $1: 함수에 전달된 첫 번째 인자
    if [[ "$level" == "red" ]]; then
        severity="red"
    elif [[ "$level" == "yellow" && "$severity" != "red" ]]; then
        # && : AND 조건. 두 조건 모두 참이어야 실행
        severity="yellow"
    fi
}

# =============================================================================
# 체크 1: PostgreSQL alive 체크
# =============================================================================
#
# pg_isready: PostgreSQL에서 제공하는 연결 테스트 도구.
#   성공(DB 살아있음) → exit code 0
#   실패(DB 죽음)     → exit code != 0
#
# ! (느낌표): 조건을 반전한다. "실패하면" 안쪽 블록을 실행.
#
# -q (quiet): 출력 없이 exit code만 반환.
#
# 2>/dev/null: stderr를 버린다. DB가 죽었을 때 나오는 에러 메시지를 숨김.
#
# [데이터 흐름]
#   pg_isready 실행 → exit code 확인 → 실패 시 Discord에 "DOWN" 알림 → exit 1로 종료
#   (DB가 죽었으면 이후 psql 쿼리도 전부 실패하므로, 여기서 바로 중단한다)
#
if ! pg_isready -h "${PG_HOST:-localhost}" -p "${PG_PORT:-5432}" -U "${PG_USER:-labuser}" -q 2>/dev/null; then
    send_discord \
        "🔴 PostgreSQL DOWN" \
        "PostgreSQL 프로세스가 응답하지 않습니다.\n\n💡 조치: \`docker compose up -d\` 또는 서버 상태 확인" \
        "$COLOR_RED"
    exit 1
    # exit 1: 스크립트를 에러 코드 1로 종료.
    # exit 0은 정상 종료, 0이 아닌 값은 비정상 종료.
fi

# =============================================================================
# 체크 2: 커넥션 사용률
# =============================================================================
#
# [SQL 설명]
#   count(*)                              → 현재 연결된 세션 수
#   current_setting('max_connections')    → postgresql.conf의 최대 연결 수 (예: 100)
#   ::numeric                             → PostgreSQL 타입 캐스팅 (정수→소수로 변환)
#   round(..., 1)                         → 소수점 1자리로 반올림
#   결과 예: "42.0" (42%)
#
# [데이터 흐름]
#   $PSQL -c "쿼리"  → psql이 쿼리를 실행하고 결과를 stdout에 출력
#   $( ... )          → 명령어 치환: stdout 출력을 변수에 저장
#   2>/dev/null       → psql 에러 메시지 숨김
#   || echo "0"       → psql이 실패하면 기본값 "0"을 사용
#                       예: DB 연결 실패 시 conn_pct="0"이 된다
#
conn_pct=$($PSQL -c "
    SELECT round(count(*)::numeric / current_setting('max_connections')::numeric * 100, 1)
    FROM pg_stat_activity;
" 2>/dev/null || echo "0")

# -----------------------------------------------------------------------------
# 임계값 비교: bc(계산기)를 사용한 소수점 비교
#
# 쉘의 (( ))는 정수만 비교 가능하다. 소수점이 있는 "42.5"를 비교하려면
# bc -l (math library)을 써야 한다.
#
# 흐름:
#   echo "$conn_pct > 95"  → "42.0 > 95" 라는 수식 문자열을 만든다
#   | bc -l                → bc가 수식을 평가: 참이면 "1", 거짓이면 "0"
#   (( ... ))              → 산술 평가: 1이면 참(true), 0이면 거짓(false)
#
# alerts+="메시지\n": 문자열 append. 기존 alerts 뒤에 새 메시지를 이어붙인다.
# -----------------------------------------------------------------------------
if (( $(echo "$conn_pct > 95" | bc -l) )); then
    alerts+="🔴 커넥션 사용률: ${conn_pct}% — pgBouncer 도입 검토\n"
    escalate red
elif (( $(echo "$conn_pct > 80" | bc -l) )); then
    alerts+="🟡 커넥션 사용률: ${conn_pct}%\n"
    escalate yellow
fi

# =============================================================================
# 체크 3: 캐시 히트율
# =============================================================================
#
# [SQL 설명]
#   blks_hit   → shared_buffers(메모리)에서 읽은 블록 수
#   blks_read  → 디스크에서 읽은 블록 수
#   히트율 = hit / (hit + read) * 100
#   nullif(x, 0) → x가 0이면 NULL을 반환 (0으로 나누기 방지)
#
# [의미]
#   99%: 거의 모든 데이터를 메모리에서 읽음 → 좋음
#   90%: 10%를 디스크에서 읽음 → shared_buffers 부족 가능성
#
cache_hit=$($PSQL -c "
    SELECT round(
        sum(blks_hit)::numeric / nullif(sum(blks_hit + blks_read), 0) * 100, 2
    ) FROM pg_stat_database;
" 2>/dev/null || echo "100")
# || echo "100": 쿼리 실패 시 100(정상)으로 간주 → 불필요한 알림 방지

# [[ -n "$cache_hit" ]]: 값이 비어있지 않은지 확인 (-n: non-empty)
# SQL이 NULL을 반환하면 빈 문자열이 될 수 있어서 이 체크가 필요하다.
if [[ -n "$cache_hit" ]] && (( $(echo "$cache_hit < 95" | bc -l) )); then
    alerts+="🟡 캐시 히트율: ${cache_hit}% (목표 ≥95%) — shared_buffers 확인\n"
    escalate yellow
fi

# =============================================================================
# 체크 4: Dead tuple 과다 테이블
# =============================================================================
#
# [SQL 설명]
#   n_dead_tup  → UPDATE/DELETE 후 남은 죽은 행 수 (VACUUM이 아직 정리 안 한 것)
#   n_live_tup  → 살아있는 행 수
#   dead_pct    → dead / live * 100 (죽은 행 비율)
#
#   || (SQL 안에서) → 문자열 연결 연산자 (쉘의 OR과 다름!)
#     예: relname || ': ' || n_dead_tup → "orders: 50000"
#
#   WHERE n_dead_tup > 10000           → dead tuple이 1만 개 이상인 테이블만
#     AND ... > 0.1                     → live 대비 10% 이상인 것만
#   LIMIT 3                            → 상위 3개만
#
# [데이터 흐름]
#   psql 쿼리 → "orders: 50000 dead (12.3%)\nusers: 20000 dead (8.5%)"
#   → dead_tables 변수에 저장
#   → 비어있지 않으면 alerts에 추가
#
dead_tables=$($PSQL -c "
    SELECT relname || ': ' || n_dead_tup || ' dead (' || round(n_dead_tup::numeric / nullif(n_live_tup, 0) * 100, 1) || '%)'
    FROM pg_stat_user_tables
    WHERE n_dead_tup > 10000
      AND n_dead_tup::numeric / nullif(n_live_tup, 0) > 0.1
    ORDER BY n_dead_tup DESC LIMIT 3;
" 2>/dev/null || echo "")

if [[ -n "$dead_tables" ]]; then
    alerts+="🟡 Dead tuple 과다:\n${dead_tables}\n"
    escalate yellow
fi

# =============================================================================
# 체크 5: 복제 지연
# =============================================================================
#
# [SQL 설명]
#   pg_stat_replication → Primary 서버에서만 데이터가 있는 뷰
#                         Replica가 없으면 결과가 0행 → coalesce로 0 반환
#   replay_lag          → Replica가 WAL을 재생하기까지의 지연 시간 (interval 타입)
#   extract(epoch FROM ...) → interval을 초 단위 숫자로 변환
#                              예: '00:01:30' → 90 (초)
#   coalesce(x, 0)      → x가 NULL이면 0을 반환 (Replica 없을 때 대비)
#
# [데이터 흐름]
#   쿼리 결과 → 정수 (초 단위) → repl_lag 변수
#   → (( )) 산술 비교 (정수이므로 bc 불필요)
#
repl_lag=$($PSQL -c "
    SELECT coalesce(
        max(extract(epoch FROM replay_lag))::integer, 0
    ) FROM pg_stat_replication;
" 2>/dev/null || echo "0")

# (( )): 산술 비교. 정수끼리 비교할 때 사용한다.
# [[ ]]와 달리 >, <, == 등 수학 기호를 직접 쓸 수 있다.
if (( repl_lag > 300 )); then
    alerts+="🔴 복제 지연: ${repl_lag}초\n"
    escalate red
elif (( repl_lag > 30 )); then
    alerts+="🟡 복제 지연: ${repl_lag}초\n"
    escalate yellow
fi

# =============================================================================
# 체크 6: 장시간 실행 쿼리 (>60초)
# =============================================================================
#
# [SQL 설명]
#   pg_stat_activity    → 현재 모든 세션 정보를 보여주는 시스템 뷰
#   state = 'active'    → 현재 쿼리를 실행 중인 세션만
#   now() - query_start → 쿼리가 시작된 이후 경과 시간 (interval)
#   > interval '60 seconds' → 60초 초과한 것만 필터
#   NOT LIKE '%pg_stat%'    → 이 스크립트 자신의 모니터링 쿼리를 제외
#   left(query, 80)         → 쿼리 텍스트의 처음 80자만 (너무 길면 Discord가 거부)
#
# [데이터 흐름]
#   쿼리 결과 예: "12345: 180초 — SELECT * FROM orders WHERE..."
#   → long_queries 변수에 저장 (여러 줄 가능)
#
long_queries=$($PSQL -c "
    SELECT pid || ': ' || extract(epoch FROM now() - query_start)::integer || '초 — ' || left(query, 80)
    FROM pg_stat_activity
    WHERE state = 'active'
      AND now() - query_start > interval '60 seconds'
      AND query NOT LIKE '%pg_stat%'
    LIMIT 3;
" 2>/dev/null || echo "")

if [[ -n "$long_queries" ]]; then
    alerts+="🟡 장시간 쿼리:\n${long_queries}\n"
    escalate yellow
fi

# =============================================================================
# 체크 7: 장시간 유지 트랜잭션 (>5분)
# =============================================================================
#
# [SQL 설명]
#   state IN ('idle in transaction', ...)
#     → BEGIN으로 트랜잭션을 시작했지만 COMMIT/ROLLBACK 하지 않고
#       방치된 상태. 이 상태가 오래 지속되면:
#       - 다른 트랜잭션의 락을 차단할 수 있음
#       - VACUUM이 dead tuple을 정리하지 못함 (bloat 유발)
#
#   xact_start → 트랜잭션이 시작된 시각 (query_start와 다름!)
#                BEGIN 시점부터 계산한다.
#
long_tx=$($PSQL -c "
    SELECT pid || ': ' || extract(epoch FROM now() - xact_start)::integer || '초'
    FROM pg_stat_activity
    WHERE state IN ('idle in transaction', 'idle in transaction (aborted)')
      AND now() - xact_start > interval '5 minutes'
    LIMIT 3;
" 2>/dev/null || echo "")

if [[ -n "$long_tx" ]]; then
    alerts+="🟡 장시간 트랜잭션 (idle in transaction):\n${long_tx}\n"
    escalate yellow
fi

# =============================================================================
# 체크 8: 디스크 사용률
# =============================================================================
#
# [명령어 분해]
#   df -h /              → 루트(/) 파일시스템의 디스크 사용량을 사람이 읽기 좋은 형태로 출력
#                          예:
#                          Filesystem  Size  Used  Avail  Use%  Mounted on
#                          /dev/sda1   50G   35G   15G    70%   /
#
#   | awk 'NR==2 {...}'  → awk는 텍스트 처리 도구.
#                          NR==2: 2번째 줄만 처리 (1번째 줄은 헤더)
#                          gsub(/%/,"")  → '%' 문자를 제거 (70% → 70)
#                          print $5      → 5번째 필드 출력 (Use% 컬럼)
#
# [데이터 흐름]
#   df 출력 → awk로 파싱 → "70" (정수 문자열) → disk_pct 변수
#
disk_pct=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}' 2>/dev/null || echo "0")

if (( disk_pct > 90 )); then
    alerts+="🔴 디스크 사용률: ${disk_pct}%\n"
    escalate red
elif (( disk_pct > 80 )); then
    alerts+="🟡 디스크 사용률: ${disk_pct}%\n"
    escalate yellow
fi

# =============================================================================
# 결과 판정 및 전송
# =============================================================================
#
# [데이터 흐름 — 정상인 경우]
#   alerts="" (빈 문자열) → 콘솔에 한 줄 출력 → exit 0 (정상 종료)
#   Discord에는 아무것도 보내지 않는다 (알림 피로 방지).
#
# [데이터 흐름 — 이상 발견 시]
#   alerts="🔴 커넥션...\n🟡 디스크...\n" (누적된 메시지)
#   severity="red" (가장 높은 심각도)
#   → case문으로 색상과 아이콘 결정
#   → send_discord()로 Discord에 전송
#

# [[ -z "$alerts" ]]: alerts가 빈 문자열인지 (-z: zero length)
if [[ -z "$alerts" ]]; then
    # 정상 — 콘솔에만 출력, Discord에는 보내지 않음 (노이즈 방지)
    echo "[$(date '+%H:%M:%S')] OK — conn:${conn_pct}% cache:${cache_hit}% disk:${disk_pct}%"
    exit 0
fi

# -----------------------------------------------------------------------------
# case 문: 여러 값에 따라 분기한다. if-elif-else의 깔끔한 대안.
#
# 문법:
#   case "$변수" in
#       패턴1) 명령어 ;;    ← ;; 로 각 분기를 끝낸다
#       패턴2) 명령어 ;;
#       *)     명령어 ;;    ← * 는 기본값 (else와 같음)
#   esac                    ← case를 뒤집은 것 (fi가 if를 뒤집은 것처럼)
# -----------------------------------------------------------------------------
case "$severity" in
    red)    color=$COLOR_RED;    icon="🔴 CRITICAL" ;;
    yellow) color=$COLOR_YELLOW; icon="🟡 WARNING" ;;
    *)      color=$COLOR_GREEN;  icon="🟢 OK" ;;
esac

# send_discord 호출 — discord-webhook.sh에서 정의한 함수
# $icon: "🔴 CRITICAL" 등 → embed 제목에 포함
# $alerts: 누적된 경고 메시지 전체 → embed 본문
# $color: Discord embed 좌측 색상 바
send_discord \
    "${icon} PostgreSQL Alert" \
    "$alerts" \
    "$color"

echo "[$(date '+%H:%M:%S')] Alert sent (${severity})"
