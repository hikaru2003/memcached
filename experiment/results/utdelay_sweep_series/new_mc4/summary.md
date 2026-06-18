# utdelay sweep / mc=4 / mutilate -T 4 -c 1 -d 32 -r 1 -u 0.5 / n=10

spinlock: [trylock -> PAUSE x N] x SPIN_ROUNDS=30 -> mutex_lock

| pause_per_round | total_pause_budget | mean_QPS | median_QPS | stddev | cv% | n |
|---|---|---|---|---|---|---|
| 3 | 90 | 1027348.2 | 1027312.8 | 862.7 | 0.08 | 10 |
