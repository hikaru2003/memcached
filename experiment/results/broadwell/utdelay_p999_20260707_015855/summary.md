# utdelay p999 sweep / mc=4 / mutilate -T 4 -c 1 -d 32 -r 1 -u 0.5 / n=1

spinlock: [PAUSE x N -> trylock] x SPIN_ROUNDS=30 -> mutex_lock
master: pthread_mutex_lock のみ（スピンなし）

| label | N | mean_QPS | median_QPS | r_p50_avg | r_p99_avg | r_p999_avg | cv% | n |
|---|---|---|---|---|---|---|---|---|
| master | master | 897728.9 | 897728.9 | 139.9 | 202.8 | 332.5 | 0.00 | 1 |
| N0 | 0 | 1109012.2 | 1109012.2 | 113.3 | 155.9 | 289.5 | 0.00 | 1 |
| N4 | 4 | 1206413.8 | 1206413.8 | 104.6 | 138.3 | 249.6 | 0.00 | 1 |
| N30 | 30 | 1405779.1 | 1405779.1 | 90.3 | 115.3 | 166.0 | 0.00 | 1 |
