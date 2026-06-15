# GET:SET ratio sweep — get100_set0

- Branch: experiment/pause-spinlock
- PAUSE values tested: 0 10 30 50 70 100
- update_ratio: 0.0 (0% SET / 100% GET)
- key range: -r 1 (single key, maximum item_lock contention)
- mc_threads: 32 / mut_threads: 4 / connections: 4
- runs per pause: 5
- date: 20260611_105225
