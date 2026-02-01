#!/usr/bin/env bash
# =============================================================================
# pg-daily-report.sh — PostgreSQL 일일 리포트 → Discord 전송
# =============================================================================
#
# [파일 역할]
#   매일 아침(cron으로 09:00에 실행) DB 상태를 요약한 리포트를 Discord로 보낸다.
#   pg-healthcheck.sh가 "이상 감지" 목적이라면,
#   이 스크립트는 "일상적인 현황 파악" 목적이다.
#
# [전체 데이터 흐름]
#   1. discord-webhook.sh source → .env 로드
#   2. 6개 SQL 쿼리 실행 → 각 결과를 report 문자열에 누적
#   3. 완성된 report를 Discord embed로 전송 (항상 초록색 — 정보성)
#
# [cron 등록 예시]
#   0 9 * * * /path/to/pg-daily-report.sh >> /var/log/pg-daily-report.log 2>&1
#   ↑ 매일 09:00
#
# [pg-healthcheck.sh와의 차이]
#   - healthcheck: 임계값 초과 시에만 알림 (경고/위험)
#   - daily report: 항상 전송 (정보 목적, 매일 1회)
#
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/discord-webhook.sh"

PSQL="psql -h ${PG_HOST:-localhost} -p ${PG_PORT:-5432} -U ${PG_USER:-labuser} -d ${PG_DB:-ecommerce} -t -A"

# report: 리포트 전체 내용을 누적할 문자열 변수.
# Discord embed의 description 필드로 전달된다.
# **굵은글씨**, ```코드블록``` 등 Discord 마크다운 문법을 사용한다.
report=""

# =============================================================================
# 섹션 1: DB 크기
# =============================================================================
#
# [SQL 설명]
#   pg_database_size(current_database())
#     → 현재 접속한 DB의 전체 크기를 바이트로 반환
#     → current_database()는 접속 중인 DB 이름 반환 (예: 'ecommerce')
#   pg_size_pretty(...)
#     → 바이트를 사람이 읽기 좋은 형태로 변환
#     → 예: 1073741824 → "1024 MB"
#
# [데이터 흐름]
#   psql → "256 MB" → db_size 변수 → report 문자열에 포맷팅하여 추가
#
db_size=$($PSQL -c "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null || echo "N/A")
report+="📦 **DB 크기**: ${db_size}\n\n"
# += : 문자열 append. report = report + "새 내용"과 같다.
# \n : 줄바꿈. Discord에서 실제 줄바꿈으로 렌더링된다.

# =============================================================================
# 섹션 2: 테이블 Top 10 크기
# =============================================================================
#
# [SQL 설명]
#   pg_class c                  → PostgreSQL의 모든 테이블/인덱스 메타 정보
#   pg_namespace n              → 스키마(namespace) 정보
#   n.nspname = 'public'        → public 스키마만 (시스템 테이블 제외)
#   c.relkind = 'r'             → 일반 테이블만 (r=regular. 인덱스, 시퀀스 등 제외)
#   pg_total_relation_size(oid) → 테이블 + 인덱스 + TOAST 합산 크기
#
#   || (SQL) → 문자열 연결 (쉘의 OR 연산자와 다름!)
#   결과 예: "orders: 128 MB\nusers: 64 MB\n..."
#
top_tables=$($PSQL -c "
    SELECT relname || ': ' || pg_size_pretty(pg_total_relation_size(c.oid))
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
    ORDER BY pg_total_relation_size(c.oid) DESC
    LIMIT 10;
" 2>/dev/null || echo "N/A")
report+="📊 **테이블 Top 10**:\n\`\`\`\n${top_tables}\n\`\`\`\n\n"
# \`\`\` : Discord 마크다운의 코드 블록. 고정폭 폰트로 정렬되어 보기 좋다.

# =============================================================================
# 섹션 3: 슬로우 쿼리 Top 5
# =============================================================================
#
# [SQL 설명]
#   pg_stat_statements → 확장(extension)이 설치되어야 사용 가능.
#                        모든 쿼리의 실행 통계를 축적하는 뷰.
#   mean_exec_time     → 쿼리당 평균 실행 시간 (밀리초)
#   calls              → 해당 쿼리가 호출된 총 횟수
#   WHERE calls > 10   → 10번 이상 실행된 쿼리만 (1회성 쿼리 제외)
#   left(query, 100)   → 쿼리 텍스트의 처음 100자만 (너무 길면 잘림)
#
# [확장 미설치 시]
#   psql이 에러 → || echo "..." 로 안내 메시지를 대신 출력한다.
#
slow_queries=$($PSQL -c "
    SELECT left(query, 100) || ' — avg: ' || round(mean_exec_time::numeric, 1) || 'ms, calls: ' || calls
    FROM pg_stat_statements
    WHERE calls > 10
    ORDER BY mean_exec_time DESC
    LIMIT 5;
" 2>/dev/null || echo "pg_stat_statements 미설치 또는 데이터 없음")
report+="🐢 **슬로우 쿼리 Top 5**:\n\`\`\`\n${slow_queries}\n\`\`\`\n\n"

# =============================================================================
# 섹션 4: Autovacuum 현황
# =============================================================================
#
# [SQL 설명]
#   pg_stat_user_tables  → 사용자 테이블의 통계 (시스템 테이블 제외)
#   last_autovacuum      → autovacuum이 마지막으로 실행된 시각
#                          NULL이면 한 번도 실행 안 된 것
#   coalesce(x::text, 'never') → NULL이면 'never' 문자열로 대체
#   n_dead_tup           → 현재 남아있는 dead tuple 수
#
#   dead tuple이 0보다 큰 테이블만 보여주어, autovacuum이 필요한 곳을 파악한다.
#
vacuum_stats=$($PSQL -c "
    SELECT relname || ' — last: ' || coalesce(last_autovacuum::text, 'never')
           || ', dead: ' || n_dead_tup
    FROM pg_stat_user_tables
    WHERE n_dead_tup > 0
    ORDER BY n_dead_tup DESC
    LIMIT 5;
" 2>/dev/null || echo "N/A")
report+="🧹 **Autovacuum 현황**:\n\`\`\`\n${vacuum_stats}\n\`\`\`\n\n"

# =============================================================================
# 섹션 5: WAL 누적 크기
# =============================================================================
#
# [SQL 설명]
#   pg_current_wal_lsn()     → 현재 WAL(Write-Ahead Log)의 위치 (LSN: Log Sequence Number)
#                               예: '0/1A3B4C00'
#   pg_wal_lsn_diff(A, B)   → 두 LSN 사이의 바이트 차이
#   '0/0'                    → WAL의 시작점
#   결과: DB 시작 이후 생성된 WAL의 총 크기
#
# [의미]
#   이 값이 하루 사이에 급격히 증가하면 대량 UPDATE/DELETE가 발생한 것이다.
#
wal_size=$($PSQL -c "
    SELECT pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')
    );
" 2>/dev/null || echo "N/A")
report+="📝 **WAL 누적 크기**: ${wal_size}\n\n"

# =============================================================================
# 섹션 6: 커넥션 / 캐시 요약
# =============================================================================
#
# [SQL 설명 — 커넥션]
#   count(*) || '/' || current_setting('max_connections')
#   → "12/100" 형태. 현재 연결 수 / 최대 연결 수
#
# [SQL 설명 — 캐시 히트율]
#   pg-healthcheck.sh의 캐시 히트율 쿼리와 동일
#
conn_info=$($PSQL -c "
    SELECT count(*) || '/' || current_setting('max_connections')
    FROM pg_stat_activity;
" 2>/dev/null || echo "N/A")
cache_hit=$($PSQL -c "
    SELECT round(sum(blks_hit)::numeric / nullif(sum(blks_hit + blks_read), 0) * 100, 2)
    FROM pg_stat_database;
" 2>/dev/null || echo "N/A")
report+="🔌 **커넥션**: ${conn_info} | **캐시 히트율**: ${cache_hit}%\n"

# =============================================================================
# 전송
# =============================================================================
#
# [데이터 흐름]
#   report 문자열 (6개 섹션 누적 완료)
#   → send_discord() 호출
#   → json_escape()로 이스케이프 → JSON payload 조립 → curl로 Discord에 POST
#   → Discord 채널에 초록색 embed 메시지가 표시됨
#
# 일일 리포트는 항상 COLOR_GREEN (초록색)으로 보낸다.
# 이상 감지는 pg-healthcheck.sh의 역할이고, 이 스크립트는 정보 제공 목적이다.
#
send_discord \
    "📋 PostgreSQL 일일 리포트" \
    "$report" \
    "$COLOR_GREEN"

echo "[$(date '+%H:%M:%S')] Daily report sent."
