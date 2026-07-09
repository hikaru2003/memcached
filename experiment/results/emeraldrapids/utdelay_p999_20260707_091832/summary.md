# utdelay p999 sweep / mc=4 / mutilate -T 4 -c 1 -d 32 -r 1 -u 0.5 / n=1

spinlock: [PAUSE x N -> trylock] x SPIN_ROUNDS=30 -> mutex_lock
master: pthread_mutex_lock のみ（スピンなし）

| label | N | mean_QPS | median_QPS | r_p50_avg | r_p99_avg | r_p999_avg | cv% | n |
|---|---|---|---|---|---|---|---|---|
| master | master | 962653.3 | 962653.3 | 130.1 | 190.6 | 221.9 | 0.00 | 1 |
| N0 | 0 | 1129344.8 | 1129344.8 | 111.3 | 155.9 | 182.0 | 0.00 | 1 |
| N4 | 4 | 1233245.1 | 1233245.1 | 102.9 | 127.8 | 151.3 | 0.00 | 1 |
| N30 | 30 | 1312506.3 | 1312506.3 | 97.0 | 124.5 | 138.1 | 0.00 | 1 |
