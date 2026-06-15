# contention sweep / get50_set50 / t=32 / mutilate -T 4 -c 4 -r 1 -u 0.5
# Method B: perf stat (context-switches, cpu-migrations, cycles, instructions)
# Method C: /proc/[pid]/status (voluntary/nonvoluntary ctx switches)
#   Note: vol_cs reads main thread only; use perf_cs for thread-wide CS count
# Auxiliary: /proc/[pid]/stat stime/utime delta (multi-thread cumulative)
#   perf stat -p overhead: ~15-20% QPS drop vs baseline (relative comparison only)

| pause_count | QPS | cs/s (perf) | cpu_migr/s | stime_pct | utime_pct | IPC | n |
|---|---|---|---|---|---|---|---|
| 0 | 147074 (+0.0%) | 161145 | 643 | 283.3% | 67.9% | 0.779 | 3 |
| 10 | 147732 (+0.4%) | 159848 | 466 | 281.4% | 69.8% | 0.775 | 3 |
| 30 | 149811 (+1.9%) | 162980 | 501 | 283.8% | 68.4% | 0.787 | 3 |
| 50 | 144532 (-1.7%) | 155898 | 446 | 277.5% | 69.6% | 0.767 | 3 |
| 70 | 157415 (+7.0%) | 175340 | 381 | 304.6% | 73.8% | 0.777 | 3 |
| 100 | 158098 (+7.5%) | 177071 | 356 | 304.5% | 76.0% | 0.775 | 3 |
