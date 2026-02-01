# 15. 1인 개발자를 위한 실전 모니터링

> "장애는 새벽 3시에 온다" — 모니터링 없이 운영하면 고객이 먼저 장애를 발견한다.

## 왜 모니터링이 필요한가

1인 또는 소규모 팀이라도 DB 모니터링은 필수다:

- **장애 조기 감지** — 커넥션 풀 고갈, 디스크 풀, 복제 지연을 잠들어 있을 때도 알 수 있다
- **성능 저하 추적** — 슬로우 쿼리나 dead tuple 축적을 일일 리포트로 파악
- **사후 분석** — 로그와 지표가 있어야 "왜 느렸는지" 근거를 찾을 수 있다

### 철학: 오버엔지니어링 금지

| 단계 | 도구 | 대상 |
|------|------|------|
| 1단계 (이 챕터) | 쉘 스크립트 + cron + Discord | 1인~3인 |
| 2단계 | + Uptime Kuma (외부 헬스체크) | 외부 가용성 필요 시 |
| 3단계 | + Grafana Cloud 무료 플랜 | 시각화 필요 시 |
| 4단계 | Prometheus + Grafana 자체 운영 | 팀 5인 이상 |

---

## 리눅스 CLI 모니터링 기초

### DB alive 체크

```bash
# pg_isready — 가장 간단한 생존 확인
pg_isready -h localhost -p 5432 -U labuser
# /tmp:5432 - accepting connections

# Docker 환경
docker exec pg17-lab pg_isready -U labuser
```

### psql로 핵심 지표 조회

```bash
# 한 줄 쿼리 실행 (-t: 헤더 제거, -A: 구분자 없음)
psql -h localhost -U labuser -d ecommerce -t -A -c "SELECT count(*) FROM pg_stat_activity;"
```

### OS 지표

```bash
df -h            # 디스크 사용률
free -m          # 메모리 (shared_buffers와 비교)
iostat -x 1 3    # 디스크 I/O (await가 높으면 문제)
vmstat 1 5       # CPU, 메모리, 스왑
```

---

## 모니터링해야 할 PostgreSQL 핵심 지표 10가지

### 1. 커넥션 사용률

**의미**: max_connections 대비 현재 연결 수. 100%에 도달하면 새 연결이 불가능해진다.

```sql
SELECT count(*)::float / current_setting('max_connections')::float * 100
       AS connection_pct
FROM pg_stat_activity;
```

| 임계값 | 대응 |
|--------|------|
| >80% | 경고 — 커넥션 누수 확인 |
| >95% | 위험 — pgBouncer 도입 또는 max_connections 증가 |

### 2. 캐시 히트율

**의미**: 디스크를 읽지 않고 shared_buffers에서 데이터를 찾은 비율. 낮으면 I/O 병목.

```sql
SELECT round(
    sum(blks_hit)::numeric / nullif(sum(blks_hit + blks_read), 0) * 100, 2
) AS cache_hit_ratio
FROM pg_stat_database;
```

| 임계값 | 대응 |
|--------|------|
| <95% | shared_buffers 증가 검토, 자주 사용하는 인덱스 확인 |
| <90% | 메모리 부족 가능성 — 서버 스펙 업그레이드 |

### 3. Dead tuple 비율

**의미**: UPDATE/DELETE 후 남은 죽은 행. autovacuum이 처리하지만 밀릴 수 있다.

```sql
SELECT schemaname, relname, n_dead_tup, n_live_tup,
       round(n_dead_tup::numeric / nullif(n_live_tup, 0) * 100, 2) AS dead_pct
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY dead_pct DESC LIMIT 5;
```

| 임계값 | 대응 |
|--------|------|
| >10% | autovacuum 설정 확인 (threshold, scale_factor) |
| >30% | 수동 VACUUM 실행, autovacuum_vacuum_cost_delay 조정 |

### 4. 장시간 실행 쿼리

**의미**: 60초 이상 실행 중인 쿼리. 락 대기나 비효율적 쿼리 가능성.

```sql
SELECT pid, now() - query_start AS duration, left(query, 100)
FROM pg_stat_activity
WHERE state = 'active'
  AND now() - query_start > interval '60 seconds';
```

| 대응 |
|------|
| EXPLAIN ANALYZE로 쿼리 플랜 확인 |
| 필요 시 `SELECT pg_cancel_backend(pid)` |

### 5. 장시간 유지 트랜잭션

**의미**: `idle in transaction` 상태가 오래 지속되면 VACUUM을 차단하고 bloat을 유발한다.

```sql
SELECT pid, now() - xact_start AS duration, state, left(query, 80)
FROM pg_stat_activity
WHERE state IN ('idle in transaction', 'idle in transaction (aborted)')
  AND now() - xact_start > interval '5 minutes';
```

| 대응 |
|------|
| 애플리케이션의 트랜잭션 관리 확인 |
| `idle_in_transaction_session_timeout` 설정 (postgresql.conf) |

### 6. 복제 지연

**의미**: Primary에서 Replica로 변경사항이 전달되는 지연 시간.

```sql
-- Primary에서 실행
SELECT client_addr, state,
       extract(epoch FROM replay_lag)::integer AS lag_seconds
FROM pg_stat_replication;
```

| 임계값 | 대응 |
|--------|------|
| >30초 | 네트워크/Replica 부하 확인 |
| >300초 | Replica가 읽기 쿼리 부하를 감당 못 하는 상태 |

### 7. 디스크 사용률

```bash
df -h /var/lib/postgresql/data
```

| 임계값 | 대응 |
|--------|------|
| >80% | 경고 — 불필요한 WAL/로그 정리 |
| >90% | 위험 — 즉시 공간 확보, VACUUM FULL 검토 |

### 8. WAL 생성량

```sql
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0'));
```

급격한 WAL 증가는 대량 UPDATE/DELETE 또는 설정 문제를 의미한다.

### 9. 슬로우 쿼리 통계

```sql
-- pg_stat_statements 확장 필요
SELECT left(query, 100), calls, round(mean_exec_time::numeric, 1) AS avg_ms,
       round(total_exec_time::numeric / 1000, 1) AS total_sec
FROM pg_stat_statements
WHERE calls > 10
ORDER BY mean_exec_time DESC LIMIT 10;
```

### 10. DB 크기 추이

```sql
SELECT pg_size_pretty(pg_database_size(current_database()));
```

일일 리포트로 추적하여 급격한 증가를 감지한다.

---

## Discord 웹훅 알림 구축

### Discord 웹훅 생성

1. Discord 서버 → 채널 설정 → 연동 → 웹훅 → 새 웹훅
2. URL 복사 → `.env` 파일에 저장

### curl로 메시지 보내기

```bash
# 간단한 텍스트
curl -H "Content-Type: application/json" \
     -d '{"content": "PostgreSQL 알림 테스트"}' \
     "$DISCORD_WEBHOOK_URL"

# Embed (색상 + 구조화)
curl -H "Content-Type: application/json" -d '{
  "embeds": [{
    "title": "🔴 PostgreSQL Alert",
    "description": "커넥션 사용률: 96%",
    "color": 15158332,
    "footer": {"text": "prod-db-01 • 2025-01-15 03:24"}
  }]
}' "$DISCORD_WEBHOOK_URL"
```

### 스크립트 구조

```
docker/monitoring/
├── .env.example         # 환경변수 템플릿
├── discord-webhook.sh   # Discord 전송 유틸리티 (source로 로드)
├── pg-healthcheck.sh    # 핵심 지표 체크 (5분마다)
├── pg-daily-report.sh   # 일일 리포트 (매일 09:00)
└── setup-cron.sh        # cron 등록
```

---

## 일일 리포트 자동화

`pg-daily-report.sh`가 매일 아침 Discord로 보내는 항목:

1. **DB 크기** — 전체 데이터베이스 크기
2. **테이블 Top 10** — 가장 큰 테이블 목록
3. **슬로우 쿼리 Top 5** — pg_stat_statements 기준
4. **Autovacuum 현황** — dead tuple이 많은 테이블
5. **WAL 누적 크기** — 비정상적 증가 감지
6. **커넥션/캐시 요약** — 현재 상태 스냅샷

---

## cron 설정

```bash
# 자동 등록
cd docker/monitoring
cp .env.example .env
# .env 편집: DISCORD_WEBHOOK_URL 설정
bash setup-cron.sh

# 수동 등록 시
crontab -e
# 추가:
# */5 * * * * /path/to/pg-healthcheck.sh >> /var/log/pg-healthcheck.log 2>&1
# 0 9 * * * /path/to/pg-daily-report.sh >> /var/log/pg-daily-report.log 2>&1
```

---

## 단계적 확장 가이드

### 2단계: Uptime Kuma (외부 헬스체크)

쉘 스크립트는 서버 내부에서 실행되므로, **서버 자체가 죽으면 알림도 죽는다.**

[Uptime Kuma](https://github.com/louislam/uptime-kuma)를 별도 서버(또는 VPS)에 설치하여 외부에서 헬스체크:

```yaml
# docker-compose.yml (별도 서버)
services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    ports:
      - "3001:3001"
    volumes:
      - uptime-data:/app/data
```

- TCP 모니터: PostgreSQL 5432 포트 체크
- HTTP 모니터: 애플리케이션 `/health` 엔드포인트
- Discord 알림 연동 가능

### 3단계: Grafana Cloud 무료 플랜

시각화가 필요해지면 [Grafana Cloud](https://grafana.com/products/cloud/) 무료 플랜:

- 메트릭 10,000개, 로그 50GB/월 무료
- Prometheus remote write로 지표 전송
- 대시보드 템플릿 활용 (PostgreSQL 대시보드 ID: 9628)

### 4단계: Prometheus + Grafana (자체 운영)

팀이 5인 이상이 되면 자체 모니터링 스택:

```
postgres_exporter → Prometheus → Grafana
                                 ↓
                              Alertmanager → Discord/Slack
```

이 단계에서는 별도의 학습이 필요하며, 이 프로젝트의 범위를 벗어난다.

---

## 실습

### 1. 스크립트 배포

```bash
cd docker/monitoring
cp .env.example .env
vim .env  # DISCORD_WEBHOOK_URL 설정

# 실행 권한
chmod +x *.sh
```

### 2. 수동 실행 테스트

```bash
# PostgreSQL이 실행 중인 상태에서
./pg-healthcheck.sh
./pg-daily-report.sh
```

### 3. 장애 시뮬레이션 — 장시간 쿼리

```bash
# 터미널 1: 느린 쿼리 실행
docker exec -it pg17-lab psql -U labuser -d ecommerce -c "
    SELECT pg_sleep(120);
"

# 터미널 2: 5분 뒤 헬스체크 실행
./pg-healthcheck.sh
# → Discord에 장시간 쿼리 경고 수신
```

### 4. 장애 시뮬레이션 — 커넥션 폭주

```bash
# 여러 커넥션 동시 생성
for i in $(seq 1 80); do
    psql -h localhost -U labuser -d ecommerce -c "SELECT pg_sleep(300);" &
done

# 헬스체크
./pg-healthcheck.sh
# → 커넥션 사용률 경고

# 정리
pkill -f "pg_sleep"
```

### 5. cron 등록

```bash
bash setup-cron.sh
crontab -l  # 확인
```

---

## 요약

| 항목 | 도구 | 주기 |
|------|------|------|
| DB alive | pg_isready | 5분 |
| 커넥션/캐시/dead tuple/복제/쿼리 | pg-healthcheck.sh | 5분 |
| DB 크기/슬로우 쿼리/vacuum/WAL | pg-daily-report.sh | 1일 |
| 알림 | Discord 웹훅 | 이상 감지 시 |

**핵심 원칙**: 정상일 때는 조용히, 이상할 때만 알림. 알림 피로(alert fatigue)를 피하자.
