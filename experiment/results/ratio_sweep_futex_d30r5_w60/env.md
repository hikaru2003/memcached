# Experiment Environment

## Date
2026-06-11

## Machine
- CPU: Intel Xeon Silver 4110 @ 2.10GHz
- Cores: 8 physical (no HyperThreading, Thread(s) per core = 1)
- NUMA: single node (NUMA node0: CPU 0-7)
- Memory: 62 GiB
- CPU governor: performance (fixed 2.10GHz)
- OS: Ubuntu 24.04 LTS (kernel 6.8.0-31-generic)

## Software
- memcached branch: experiment/pause-spinlock
- memcached commit: 459eb6b (experiment: replace item_locks with TTAS spinlock (configurable PAUSE count))
- mutilate: version 0.1

## Experiment Parameters
- mc_threads: 32
- mut_threads: 4 / connections: 4
- key range: -r 1 (single key, maximum item_lock contention)
- warmup: 60s
- duration: 30s
- runs per condition: 5
- PAUSE_VALUES: 0 10 30 50 70 100
- UPDATE_RATIO_VALUES: 0.0 0.1 0.3 0.5 0.7 0.9 1.0

## spinlock Implementation
- item_locks (thread.c): pthread_mutex_t → spinlock_t
- slabs_lock (slabs.c): pthread_mutex_t → spinlock_t
- Behavior: [pthread_mutex_trylock → cpu_relax(PAUSE)] × N → pthread_mutex_lock
- PAUSE_COUNT=0: no spinning, immediate pthread_mutex_lock (functionally master-equivalent)

## Master Baseline
- Binary: ./memcached_master (built from master branch, no spinlock changes)
- Same warmup/duration/runs as above
