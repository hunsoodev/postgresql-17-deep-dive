# 14. 설정 튜닝 벤치마크

> postgresql.conf 설정을 변경하고 pgbench로 측정한 결과를 기록하세요.

---

## pgbench 초기화

```bash
docker exec -it pg17-lab pgbench -i -s 50 -U labuser ecommerce
```

## 기본 측정 명령

```bash
# 10초간 4클라이언트 벤치마크
docker exec -it pg17-lab pgbench -c 4 -j 2 -T 10 -U labuser ecommerce
```

---

## 테스트 1: shared_buffers 변경

### 결과 비교
| 항목 | 32MB | 128MB | 256MB |
|------|------|-------|-------|
| TPS (excluding connections) | | | |
| Avg latency (ms) | | | |
| Stddev latency (ms) | | | |

### OS 지표 (`vmstat` / `iostat`)
| 항목 | 32MB | 128MB | 256MB |
|------|------|-------|-------|
| CPU user% | | | |
| CPU sys% | | | |
| IO read/s | | | |
| IO write/s | | | |

### 분석
- (기록)

---

## 테스트 2: work_mem 변경

### 조건
정렬이 포함된 복잡한 쿼리로 테스트

### 결과 비교
| 항목 | 1MB | 4MB | 16MB |
|------|-----|-----|------|
| Sort Method | | | |
| 실제 시간(ms) | | | |
| Temp files written | | | |

### 분석
- (기록)

---

## 테스트 3: checkpoint 설정

### 결과 비교
| 항목 | 기본값 | max_wal_size=2GB | checkpoint_timeout=15min |
|------|--------|-----------------|------------------------|
| TPS | | | |
| Checkpoint 횟수 | | | |
| WAL 생성량 | | | |
| Avg latency (ms) | | | |

### 분석
- (기록)

---

## 테스트 4: 최적 설정 조합

### 조건
위 테스트 결과를 종합하여 최적 설정 적용

### 기본 vs 최적 비교
| 항목 | 기본 설정 | 최적 설정 |
|------|----------|----------|
| shared_buffers | 128MB | |
| work_mem | 4MB | |
| max_wal_size | 1GB | |
| checkpoint_timeout | 5min | |
| TPS | | |
| Avg latency (ms) | | |
| 개선율 | baseline | |

### 분석
- (기록)
