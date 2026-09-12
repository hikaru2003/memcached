# utdelay p999 sweep / mc=4 / mutilate -T 4 -c 1 -d 32 -r 1 -u 0.5 / n=1

spinlock: [PAUSE x N -> trylock] x SPIN_ROUNDS=30 -> mutex_lock
master: pthread_mutex_lock のみ（スピンなし）

| label | N | mean_QPS | median_QPS | r_p50_avg | r_p99_avg | r_p999_avg | cv% | n |
|---|---|---|---|---|---|---|---|---|
| master | master | 911258.4 | 911258.4 | 137.9 | 197.9 | 323.0 | 0.00 | 1 |
| N0 | 0 | 1079672.4 | 1079672.4 | 116.1 | 163.6 | 307.0 | 0.00 | 1 |
