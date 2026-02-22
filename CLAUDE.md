# CLAUDE.md — 프로젝트 상태 및 계획

## 프로젝트 개요

PostgreSQL 17 심화 학습 프로젝트. 공식 문서 기반 + OS 파일시스템 연계 설명 + Docker 실습.
실습 도메인: 이커머스 쇼핑몰 (users, products, orders, event_logs 등)

## 완료된 작업

### 1단계: 전체 파일 생성 (완료)
- [x] `.gitignore`, `README.md`
- [x] `docker/` — docker-compose.yml, docker-compose.repl.yml, postgresql.conf, init.sql
- [x] `notes/` — 14개 챕터 학습 노트 (01~14)
- [x] `diagrams/` — 7개 draw.io 다이어그램
- [x] `benchmarks/` — README + 4개 벤치마크 템플릿 (06, 07, 11, 14)

### 2단계: GitHub push (완료)
- [x] 리포지토리: https://github.com/hunsoodev/postgresql-17-deep-dive
- [x] 커밋: `docs: add complete PostgreSQL 17 learning materials` (32파일, 22,897줄)

### 이미지 추가 (완료)
- [x] [The Internals of PostgreSQL](https://www.interdb.jp/pg/) 사이트에서 138개 다이어그램 다운로드
- [x] `docs/images/` 디렉토리에 챕터별 정리 (ch01~ch11, 7MB)
- [x] `docs/image-manifest.md` — 이미지 목록 + 노트 매핑 가이드
- [x] notes 01~08, 13~14에 관련 이미지 삽입 (총 ~48개 이미지 참조)

### 노트 리팩토링: 이론-실습 통합 (진행 중)
- [x] `notes/01-architecture-and-os.md` — 이론-실습 통합 구조로 리팩토링
  - 노트 내 별도 docker-compose.yml 제거, `docker/` 디렉토리 참조로 통일
  - 개념 설명 직후 `✅ 직접 확인:` 블록으로 실습 배치
  - 설정값을 실제 환경(pg17-lab, labuser, ecommerce)과 일치시킴
  - 기존 "실습 SQL" / "직접 확인해보기" 별도 섹션 → 해당 이론 직후로 이동
- [x] `notes/01-architecture-and-os.md` — 심화 개념 설명 추가 (+385줄)
  - background workers 각 역할을 비유와 면접 답변 예시로 재작성
  - checkpoint 분산 쓰기(completion_target), 발생 조건(시간/WAL 크기) 상세
  - WAL 전체 흐름 (버퍼→파일→데이터), 크래시 시점별 시나리오 테이블
  - MVCC 간략 설명 (xmin/xmax, dead tuple이 남는 이유)
  - 공유 메모리 세그먼트/페이지 용어 정리, OS 페이지(4KB) vs PG 블록(8KB) 구분
  - 세마포어 이론 및 뮤텍스와의 차이, PG 세마포어 수 계산식
  - 락 계층 4단계 (SpinLock→LWLock→행 락→테이블 락) 비유와 SQL 예시
  - pg_stat_checkpointer (v17 신규) / pg_stat_bgwriter (v17 변경) 주석
- [x] `notes/01-architecture-and-os.md` — 프로덕션 심화 + 락 실전 시나리오 대폭 추가 (+2800줄)
  - bgwriter 파라미터 (bgwriter_delay/lru_maxpages/lru_multiplier), pg_stat_io 모니터링
  - WAL writer 파라미터, write vs fsync, synchronous_commit 관계
  - 백그라운드 워커 모니터링 컬럼별 상세 (pg_stat_checkpointer/bgwriter/wal)
  - work_mem per-operation 설명, 곱셈 위험, SET LOCAL 패턴
  - shared_buffers: 캐시 히트/미스, Clock Sweep, pg_buffercache 6개 쿼리
  - pg_statio_user_tables 8개 컬럼 상세, 패턴별 판단 테이블
  - Transaction ID wraparound: 메커니즘, freezing, 모니터링 5개 쿼리, 긴급 복구
  - 락 4단계 현업 시나리오 (각 단계별 진단→해결→예방 단계 포함):
    - SpinLock: CPU 코어 수 관계 (busy-wait 역전 현상), PgBouncer 도입 단계
    - LWLock: WALInsertLock/BufferMapping/buffer_content 경합 진단 및 해결
    - 행 락: 재고 차감, 결제 이중 처리(3가지 방법), 작업 큐(SKIP LOCKED 완전 패턴), 좌석 예매
    - 테이블 락: 마이그레이션 사고 대응, CREATE INDEX CONCURRENTLY, VACUUM FULL→pg_repack, idle in transaction
  - 테이블 락 8가지 모드 상세 (각 모드별 SQL/충돌/예시/이유)
  - 8×8 충돌 매트릭스, DML끼리 충돌하지 않는 이유 (2단계 락 설계)
  - MVCC로 SELECT-UPDATE 비블로킹 설명 (xmin/xmax 버전 관리, MySQL InnoDB 비교)
  - FOR UPDATE 3가지 변형 비교 (기본/NOWAIT/SKIP LOCKED)
  - pg_locks 행 락 진단 쿼리 절별 컬럼 상세 해설
  - ALTER TABLE별 필요 락 모드 구분 (AccessExclusive vs 그 외)
- [x] `notes/13-backup-replication.md` — 프로덕션 WAL 아카이빙 전략 추가
  - S3/R2 직접 아카이빙, pgBackRest (권장), barman
  - 복구 흐름, 도구 비교 테이블
- [x] `notes/17-pgvector-index-tuning.md` — pgvector 인덱스 튜닝 가이드 신규 생성
  - HNSW vs IVFFlat 비교, 파라미터 튜닝 (m, ef_construction, lists, probes)
  - 빌드 최적화, 필터링 전략, 저장 최적화 (halfvec, binary quantization)
  - PG17 특화 기능
- [x] `notes/12-1-permission-management.md` — 권한 관리 노트 추가
- [x] `notes/16-data-engineering-sql.md` — 데이터 엔지니어링 SQL 노트 추가
- [x] `docker/postgresql.conf` — 전체 파라미터 상세 주석 추가
  - ~30개 설정 항목마다: 동작 원리, 이 값인 이유, 잘못 설정 시 영향, 프로덕션 권장값
  - 파일 상단에 설정 우선순위(8단계), 유용한 조회 쿼리, 전체 레퍼런스 링크 추가
- [ ] `notes/02~14` — 나머지 노트 이론-실습 통합 (예정)

## 다음 단계

### 3단계: 리눅스 서버에서 실습
1. `git clone` → `docker compose up -d`로 PostgreSQL 17 기동
2. 학습 노트 순서대로 실습 진행:

#### 기반 지식 (01~05)
- [ ] 01: 프로세스 확인 (`ps aux`, `pg_stat_activity`), 공유 메모리 크기 확인
- [ ] 02: PGDATA 탐색, `pg_relation_filepath()`, `pageinspect`로 페이지 확인
- [ ] 03: `pg_waldump`, `pg_current_wal_lsn()`, WAL 파일 관찰
- [ ] 04: xmin/xmax 확인, 격리 수준 재현, 데드락 시나리오
- [ ] 05: VACUUM VERBOSE, dead tuple 확인, 파일 크기 비교

#### 실전 스킬 (06~09)
- [ ] 06: 인덱스 타입별 EXPLAIN 비교 → `benchmarks/06-index-comparison.md` 기록
- [ ] 07: 느린 쿼리 개선 → `benchmarks/07-query-optimization.md` 기록
- [ ] 08: 스키마 분석, 컬럼 정렬/패딩, `pg_column_size()` 확인
- [ ] 09: Window Functions, Recursive CTE, JSON_TABLE (v17)

#### 응용 (10~12)
- [ ] 10: 트리거 작성 (updated_at, 감사 로그, 재고 감소)
- [ ] 11: 파티셔닝 프루닝 확인 → `benchmarks/11-partition-pruning.md` 기록
- [ ] 12: Role + RLS 설정

#### 운영 심화 (13~15)
- [ ] 13: `docker-compose.repl.yml`로 Primary+Replica 구성, PITR 실습
- [ ] 14: `postgresql.conf` 튜닝 → pgbench → `benchmarks/14-tuning-pgbench.md` 기록
- [ ] 15: 모니터링 스크립트 배포 → cron 설정 → 장애 시뮬레이션 → Discord 알림 확인

### 실습 중 커밋 전략
- 벤치마크 결과 추가: `bench: add index comparison results for chapter 06`
- 다이어그램 수정: `docs: update process architecture diagram`
- 노트 보완: `docs: add clarification to WAL chapter`

## 파일 구조

```
db-learning/
├── CLAUDE.md                  ← 이 파일
├── README.md
├── docs/
│   ├── image-manifest.md      # 이미지 목록 + 노트 매핑
│   └── images/                # The Internals of PostgreSQL 다이어그램 (138개)
│       ├── ch01/ ~ ch03/
│       ├── ch05/ ~ ch11/
├── .gitignore
├── docker/
│   ├── docker-compose.yml     # 단일 PostgreSQL 17
│   ├── docker-compose.repl.yml # Primary + Replica
│   ├── postgresql.conf        # 커스텀 설정
│   ├── init.sql               # 이커머스 스키마 + 테스트 데이터
│   └── monitoring/            # 모니터링 스크립트 (Discord 알림)
├── notes/                     # 17개 챕터 (01~17, 12-1 포함)
├── diagrams/                  # 7개 .drawio 파일
└── benchmarks/                # EXPLAIN 벤치마크 기록
```

## 실습 환경

- PostgreSQL 17 (Docker 공식 이미지)
- 테스트 데이터: users 10만, orders 50만, event_logs 100만
- 접속: `docker exec -it pg17-lab psql -U labuser -d ecommerce`

## 참고

- PostgreSQL 17 공식 문서: https://www.postgresql.org/docs/17/
- draw.io 편집: https://app.diagrams.net/
