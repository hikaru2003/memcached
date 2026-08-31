# Approach A 実験まとめ

- 実行日時: 2026-08-31 09:47:24
- N values: 0 25 50 100 200
- warmup: 60s / duration: 30s / runs: 3
- spin_rounds: 30
- 所要時間推定: ~82 min

## 目的

N を固定してスレッド数を変化させ、「スレッド増加 → RFO増加 → handoff latency増加」の因果を確認する。

| MC_THREADS | MC_CPUS | WL_CPUS |
|---|---|---|
| 2 | 0-1 | 4-7 |
| 4 | 0-3 | 4-7 |
| 8 | 0-7 | 8-11 |

## 結果ディレクトリ

### handoff sweep
- T2: `experiment/results/handoff_20260831_082313`
  - handoff_summary.csv: **あり**
  ```
  condition,n_samples,tsc_mhz,min_us,p10_us,p25_us,p50_us,p75_us,p90_us,p95_us,p99_us,p999_us,max_us
  N0,2097152,2100.0,0.0676,0.0857,0.1581,0.3010,0.5486,1.1019,1.6762,4.0190,6.8962,47.7914
  N25,2097152,2100.0,0.0676,0.0790,0.1343,0.3143,0.5857,1.0419,1.6390,3.8648,6.7524,165.7410
  N50,2097152,2100.0,0.0676,0.0771,0.1295,0.3333,0.5924,1.1229,1.7038,3.7267,6.5790,50.2162
  ```
- T4: `experiment/results/handoff_20260831_085116`
  - handoff_summary.csv: **あり**
  ```
  condition,n_samples,tsc_mhz,min_us,p10_us,p25_us,p50_us,p75_us,p90_us,p95_us,p99_us,p999_us,max_us
  N0,4194304,2100.0,0.0686,0.1610,0.1933,0.3029,0.5429,1.3181,1.8990,3.0762,4.7883,24.8457
  N25,4194304,2100.0,0.0676,0.1267,0.1648,0.2752,0.5933,1.0657,1.4486,2.4819,3.9876,51.7895
  N50,4194304,2100.0,0.0667,0.1162,0.1629,0.3171,0.6048,1.1390,1.4886,2.5943,4.1848,47.5619
  ```
- T8: `experiment/results/handoff_20260831_091919`
  - handoff_summary.csv: **あり**
  ```
  condition,n_samples,tsc_mhz,min_us,p10_us,p25_us,p50_us,p75_us,p90_us,p95_us,p99_us,p999_us,max_us
  N0,8388608,2100.0,0.0686,0.1590,0.1914,0.3019,0.5476,1.3267,1.9133,3.1343,4.9105,19.3667
  N25,8388608,2100.0,0.0676,0.1210,0.1581,0.2705,0.5848,1.0476,1.4295,2.4524,3.9390,52.8286
  N50,8388608,2100.0,0.0676,0.1181,0.1590,0.3124,0.5962,1.1286,1.4743,2.5590,4.1038,15.3876
  ```

### cache_miss sweep
- T2: `experiment/results/cache_miss_20260831_083601`
  - summary.csv: **あり**
  ```
  label,pause_per_round,spin_rounds,total_pause_budget,run,QPS,r_p99_us,r_p999_us,cache_misses,LLC_load_misses,demand_rfo,cache_references,llc_miss_rate_pct
  master,master,30,0,1,1051476.5,156.0,174.9,N/A,N/A,N/A,N/A,N/A
  master,master,30,0,2,1051356.6,156.0,175.5,N/A,N/A,N/A,N/A,N/A
  master,master,30,0,3,1051325.4,156.0,175.2,N/A,N/A,N/A,N/A,N/A
  ```
- T4: `experiment/results/cache_miss_20260831_090405`
  - summary.csv: **あり**
  ```
  label,pause_per_round,spin_rounds,total_pause_budget,run,QPS,r_p99_us,r_p999_us,cache_misses,LLC_load_misses,demand_rfo,cache_references,llc_miss_rate_pct
  master,master,30,0,1,983781.6,207.8,247.6,51831,1422,330001273,1516090350,0.0034
  master,master,30,0,2,983131.0,207.7,247.3,54792,1640,328467591,1509782459,0.0036
  master,master,30,0,3,983616.6,207.9,247.6,63885,1964,328216721,1515734204,0.0042
  ```
- T8: `experiment/results/cache_miss_20260831_093209`
  - summary.csv: **あり**
  ```
  label,pause_per_round,spin_rounds,total_pause_budget,run,QPS,r_p99_us,r_p999_us,cache_misses,LLC_load_misses,demand_rfo,cache_references,llc_miss_rate_pct
  master,master,30,0,1,985683.5,207.5,252.1,152318,5421,331083240,1528123614,0.0100
  master,master,30,0,2,986755.6,207.4,253.9,174381,7200,330800093,1544682460,0.0113
  master,master,30,0,3,985357.7,207.3,251.8,174544,6237,331529874,1518376697,0.0115
  ```

## push コマンド

```bash
cd ~/Application/memcached
EXPERIMENT_TYPE=handoff bash experiment/push_results.sh
EXPERIMENT_TYPE=cache_miss bash experiment/push_results.sh
```

## 期待する結果

固定 N（例: N=50）でスレッド数を増やすと:

| MC_THREADS | demand_rfo/req | handoff p99 |
|---|---|---|
| 2 | 低 | 短 |
| 4 | 中 | 中 |
| 8 | 高 | 長 |

両者が同方向に増加すれば「RFO増加 → handoff latency増加」の相関が確認できる。

---
生成: 2026-08-31 09:47:24
