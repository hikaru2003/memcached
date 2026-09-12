# utdelay p999 sweep / mc=4 / mutilate -T 4 -c 1 -d 32 -r 1 -u 0.5 / n=1

spinlock: [PAUSE x N -> trylock] x SPIN_ROUNDS=30 -> mutex_lock
master: pthread_mutex_lock のみ（スピンなし）

| label | N | mean_QPS | median_QPS | r_p50_avg | r_p99_avg | r_p999_avg | cv% | n |
|---|---|---|---|---|---|---|---|---|
| master | master | 960716.4 | 960716.4 | 130.4 | 190.8 | 221.5 | 0.00 | 1 |
| N0 | 0 | 1128264.3 | 1128264.3 | 111.4 | 156.3 | 182.7 | 0.00 | 1 |
