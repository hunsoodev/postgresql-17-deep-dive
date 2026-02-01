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
├── notes/                     # 15개 챕터 (01~15)
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
