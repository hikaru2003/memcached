# utdelay p999 sweep / mc=4 / mutilate -T 4 -c 1 -d 32 -r 1 -u 0.5 / n=1

spinlock: [PAUSE x N -> trylock] x SPIN_ROUNDS=30 -> mutex_lock
master: pthread_mutex_lock のみ（スピンなし）

| label | N | mean_QPS | median_QPS | r_p50_avg | r_p99_avg | r_p999_avg | cv% | n |
|---|---|---|---|---|---|---|---|---|
| master | master | 959430.8 | 959430.8 | 130.6 | 190.9 | 221.9 | 0.00 | 1 |
| N0 | 0 | 1115761.5 | 1115761.5 | 112.3 | 162.9 | 186.8 | 0.00 | 1 |
| N4 | 4 | 1222403.6 | 1222403.6 | 103.7 | 128.2 | 153.6 | 0.00 | 1 |
| N30 | 30 | 1318526.5 | 1318526.5 | 96.5 | 123.8 | 137.5 | 0.00 | 1 |
