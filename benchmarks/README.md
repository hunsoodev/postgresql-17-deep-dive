# 벤치마크 기록 가이드

실습 중 `EXPLAIN ANALYZE` 결과를 이 디렉토리에 기록합니다.

## 기록 형식

```markdown
## 테스트: [테스트 설명]

### 조건
- 테이블 크기: N행
- 쿼리: `SELECT ...`
- 환경: Docker PostgreSQL 17, shared_buffers=128MB

### 결과 비교
| 항목 | 조건A | 조건B | 조건C |
|------|-------|-------|-------|
| 스캔 방식 | Seq Scan | Index Scan | ... |
| 예상 cost | ... | ... | ... |
| 실제 시간(ms) | ... | ... | ... |
| Buffers shared hit | ... | ... | ... |
| Buffers shared read | ... | ... | ... |
| 행 반환 | ... | ... | ... |

### 분석
- (결과에 대한 분석)
```

## EXPLAIN 실행 방법

```sql
-- 기본 실행계획 (실행 안 함)
EXPLAIN SELECT ...;

-- 실제 실행 + 버퍼 통계
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) SELECT ...;

-- JSON 형식 (상세 정보)
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT ...;
```

## 주의사항

- 벤치마크 전 `DISCARD ALL;`로 세션 캐시 초기화
- 여러 번 실행하여 평균값 사용 (첫 실행은 OS 캐시 cold start)
- `shared_buffers` 캐시 영향을 줄이려면 `pg_prewarm` 또는 재시작 후 측정
