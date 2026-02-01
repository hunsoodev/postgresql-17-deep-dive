# PostgreSQL 17 심화 학습 프로젝트

PostgreSQL 17 기반 심화 학습 — 친절한 개념 설명 + Docker 실습 병행

## 특징

- **공식 문서 기반**: [PostgreSQL 17 Documentation](https://www.postgresql.org/docs/17/) 참조
- **OS 파일시스템 연계**: PostgreSQL이 OS 위에서 어떻게 동작하는지 저수준까지 설명
- **초보자 친화적**: 고급 내용도 "왜 이게 필요한지"부터 시작
- **실습 중심**: Docker 환경에서 바로 실행 가능한 예제 포함
- **실습 도메인**: 이커머스 쇼핑몰 (users, products, orders 등 실무적 스키마)

## 학습 로드맵

### 기반 지식 (01~05)
| # | 주제 | 핵심 내용 |
|---|------|----------|
| 01 | [아키텍처와 OS 프로세스](notes/01-architecture-and-os.md) | 멀티프로세스 모델, 공유 메모리, IPC |
| 02 | [스토리지와 파일시스템](notes/02-storage-and-filesystem.md) | 8KB 페이지, PGDATA 구조, TOAST |
| 03 | [WAL과 신뢰성](notes/03-wal-and-reliability.md) | Write-Ahead Log, checkpoint, fsync |
| 04 | [MVCC와 동시성 제어](notes/04-mvcc-and-concurrency.md) | xmin/xmax, 격리 수준, 락 |
| 05 | [VACUUM과 유지관리](notes/05-vacuum-and-maintenance.md) | dead tuple, autovacuum, wraparound |

### 실전 스킬 (06~09)
| # | 주제 | 핵심 내용 |
|---|------|----------|
| 06 | [인덱스 심화](notes/06-indexes.md) | B-tree, GIN, BRIN, 벤치마크 |
| 07 | [쿼리 최적화와 EXPLAIN](notes/07-query-optimization.md) | EXPLAIN ANALYZE, 플래너, 통계 |
| 08 | [데이터 모델링](notes/08-data-modeling.md) | 정규화, 타입 선택, 정렬/패딩 |
| 09 | [고급 SQL](notes/09-advanced-sql.md) | Window, CTE, JSONB, v17 JSON_TABLE |

### 응용 (10~12)
| # | 주제 | 핵심 내용 |
|---|------|----------|
| 10 | [PL/pgSQL과 서버 프로그래밍](notes/10-plpgsql.md) | 함수, 프로시저, 트리거 |
| 11 | [파티셔닝과 대용량](notes/11-partitioning.md) | Range/List/Hash, 프루닝, COPY |
| 12 | [보안과 접근 제어](notes/12-security.md) | Role, RLS, pg_hba.conf |

### 운영 심화 (13~15)
| # | 주제 | 핵심 내용 |
|---|------|----------|
| 13 | [백업, 복구, 복제](notes/13-backup-replication.md) | pg_basebackup, PITR, Streaming Replication |
| 14 | [모니터링과 성능 튜닝](notes/14-monitoring-and-tuning.md) | postgresql.conf, pgbench, 통계 뷰 |
| 15 | [실전 모니터링](notes/15-practical-monitoring.md) | 쉘 스크립트, Discord 알림, cron 자동화 |

## 빠른 시작

```bash
# 1. 리포지토리 클론
git clone <your-repo-url>
cd db-learning

# 2. Docker로 PostgreSQL 17 실행
cd docker
docker compose up -d

# 3. psql 접속
docker exec -it pg17-lab psql -U labuser -d ecommerce

# 4. 복제 실습 (Primary + Replica)
docker compose -f docker-compose.repl.yml up -d
```

## 디렉토리 구조

```
db-learning/
├── README.md                  # 이 파일
├── .gitignore
├── docker/                    # Docker 실습 환경
│   ├── docker-compose.yml     # 단일 PostgreSQL 17
│   ├── docker-compose.repl.yml # Primary + Replica
│   ├── postgresql.conf        # 커스텀 설정
│   ├── init.sql               # 이커머스 스키마 + 테스트 데이터
│   └── monitoring/            # 모니터링 스크립트 (Discord 알림)
├── notes/                     # 14개 챕터 학습 노트
├── diagrams/                  # draw.io 다이어그램 (.drawio)
└── benchmarks/                # EXPLAIN 벤치마크 기록
```

## 벤치마크 기록 방법

실습 중 EXPLAIN ANALYZE 결과를 `benchmarks/` 디렉토리에 기록합니다.
자세한 형식은 [benchmarks/README.md](benchmarks/README.md)를 참고하세요.

## 다이어그램

`diagrams/` 디렉토리의 `.drawio` 파일을 [draw.io](https://app.diagrams.net/)에서 열어 편집할 수 있습니다.

## 환경 요구사항

- Docker & Docker Compose
- psql 클라이언트 (또는 Docker exec으로 접속)
- draw.io (다이어그램 편집용, 선택사항)
