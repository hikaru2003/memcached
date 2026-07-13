# utdelay p999 sweep / mc=4 / mutilate -T 4 -c 1 -d 32 -r 1 -u 0.5 / n=1

spinlock: [PAUSE x N -> trylock] x SPIN_ROUNDS=30 -> mutex_lock
master: pthread_mutex_lock のみ（スピンなし）

| label | N | mean_QPS | median_QPS | r_p50_avg | r_p99_avg | r_p999_avg | cv% | n |
|---|---|---|---|---|---|---|---|---|
| master | master | 955812.0 | 955812.0 | 131.1 | 192.8 | 223.1 | 0.00 | 1 |
| N0 | 0 | 1123923.8 | 1123923.8 | 111.7 | 158.6 | 184.4 | 0.00 | 1 |
| N4 | 4 | 1219055.6 | 1219055.6 | 104.0 | 128.3 | 153.4 | 0.00 | 1 |
| N30 | 30 | 1305902.5 | 1305902.5 | 97.5 | 125.1 | 138.4 | 0.00 | 1 |
