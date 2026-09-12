# utdelay p999 sweep / mc=4 / mutilate -T 4 -c 1 -d 32 -r 1 -u 0.5 / n=1

spinlock: [PAUSE x N -> trylock] x SPIN_ROUNDS=30 -> mutex_lock
master: pthread_mutex_lock のみ（スピンなし）

| label | N | mean_QPS | median_QPS | r_p50_avg | r_p99_avg | r_p999_avg | cv% | n |
|---|---|---|---|---|---|---|---|---|
| master | master | 1084108.8 | 1084108.8 | 115.5 | 173.5 | 203.0 | 0.00 | 1 |
| N0 | 0 | 1106659.2 | 1106659.2 | 114.1 | 154.7 | 179.3 | 0.00 | 1 |
