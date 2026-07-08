# utdelay p999 sweep / mc=4 / mutilate -T 4 -c 1 -d 32 -r 1 -u 0.5 / n=1

spinlock: [PAUSE x N -> trylock] x SPIN_ROUNDS=30 -> mutex_lock
master: pthread_mutex_lock のみ（スピンなし）

| label | N | mean_QPS | median_QPS | r_p50_avg | r_p99_avg | r_p999_avg | cv% | n |
|---|---|---|---|---|---|---|---|---|
| master | master | 719658.7 | 719658.7 | 176.0 | 247.9 | 276.4 | 0.00 | 1 |
| N0 | 0 | 939638.2 | 939638.2 | 134.0 | 178.6 | 206.8 | 0.00 | 1 |
| N4 | 4 | 958094.0 | 958094.0 | 131.7 | 169.1 | 195.1 | 0.00 | 1 |
| N30 | 30 | 1012780.4 | 1012780.4 | 125.3 | 152.8 | 185.4 | 0.00 | 1 |
