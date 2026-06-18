# Run info (futex sweep)
- date: (reconstructed from experiment/futex_sweep_out.log)
- branch: debug/futex-count
- binary: ./memcached_debug_futex
- mc_threads: 4 (cpus: 0-3)
- mut: -T 4 -c 1 -d 32 (total_conns=4)
- update_ratio: 0.5 / records: 1
- warmup: 60s / duration: 30s / runs: 3
- pause_values: 0 10 20 30 40 50 60 70 80 90 100 200 300
- note: reconstructed from futex_sweep_out.log (raw mutilate logs lost)
