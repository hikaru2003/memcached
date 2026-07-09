# utdelay p999 sweep / mc=4 / mutilate -T 4 -c 1 -d 32 -r 1 -u 0.5 / n=1

spinlock: [PAUSE x N -> trylock] x SPIN_ROUNDS=30 -> mutex_lock
master: pthread_mutex_lock のみ（スピンなし）

| label | N | mean_QPS | median_QPS | r_p50_avg | r_p99_avg | r_p999_avg | cv% | n |
|---|---|---|---|---|---|---|---|---|
| master | master | 952913.2 | 952913.2 | 131.5 | 193.4 | 223.5 | 0.00 | 1 |
| N0 | 0 | 1140070.2 | 1140070.2 | 110.4 | 154.7 | 178.9 | 0.00 | 1 |
| N4 | 4 | 1229812.7 | 1229812.7 | 103.2 | 128.0 | 153.2 | 0.00 | 1 |
| N30 | 30 | 1307526.4 | 1307526.4 | 97.4 | 125.0 | 138.9 | 0.00 | 1 |
