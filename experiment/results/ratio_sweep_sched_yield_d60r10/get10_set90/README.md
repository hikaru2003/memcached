# GET:SET ratio sweep — get10_set90

- Branch: experiment/pause-spinlock
- PAUSE values tested: 0 10 40 100
- update_ratio: 0.9 (90% SET / 10% GET)
- key range: -r 1 (single key, maximum item_lock contention)
- mc_threads: 32 / mut_threads: 4 / connections: 4
- runs per pause: 10
- date: 20260610_180737
