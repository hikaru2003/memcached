#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_utdelay_sweep.sh
#
# Parameters (env vars, all optional):
#   MEMCACHED_BIN      - path to memcached binary                  (default: ./memcached)
#   MUTILATE_BIN       - path to mutilate binary                   (default: ../mutilate/mutilate)
#   WARMUP_SEC         - warmup duration in seconds per run        (default: 10)
#   DURATION           - measurement duration in seconds per run   (default: 30)
#   RUNS               - number of repeated measurements per N     (default: 5)
#   MC_THREADS         - memcached worker threads                  (default: 32)
#   MUT_THREADS        - mutilate client threads                   (default: 4)
#   MUT_CONNS          - mutilate connections per thread           (default: 4)
#   RECORDS            - key range                                 (default: 1)
#   UPDATE_RATIO       - set:total ratio 0.0-1.0                   (default: 0.5)
#   PORT               - memcached port                            (default: 11222)
#   SPIN_ROUNDS        - fixed number of (trylock+delay) cycles    (default: 30)
#   PAUSE_PER_ROUND_VALUES - space-separated N values to sweep
#                            (default: "0 1 2 3 5 7 10 15 20 30")
#
# Spinlock pattern (MySQL/InnoDB-like ut_delay):
#   [trylock -> cpu_relax x N] x ROUNDS -> pthread_mutex_lock (futex)
#
# Output:
#   experiment/results/utdelay_sweep_YYYYMMDD_HHMMSS/
#     summary.csv          - per-N statistics (mean/median/stddev/min/max/cv QPS)
#     raw.csv              - all individual run QPS values
#     run_N<N>_<run>.log   - raw mutilate output per (N, run)
#
# Prerequisites:
#   - memcached built on experiment/mysql-like-utdelay branch
#   - mutilate binary at ../mutilate/mutilate

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
WARMUP_SEC="${WARMUP_SEC:-10}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-5}"
MC_THREADS="${MC_THREADS:-32}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-4}"
RECORDS="${RECORDS:-1}"
UPDATE_RATIO="${UPDATE_RATIO:-0.5}"
PORT="${PORT:-11222}"
SPIN_ROUNDS="${SPIN_ROUNDS:-30}"
PAUSE_PER_ROUND_VALUES="${PAUSE_PER_ROUND_VALUES:-0 1 2 3 5 7 10 15 20 30}"

RESULT_DIR="experiment/results/utdelay_sweep_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULT_DIR"

echo "pause_per_round,spin_rounds,mean_QPS,median_QPS,stddev_QPS,min_QPS,max_QPS,cv_pct,read_avg_us,read_p99_us" \
    > "$RESULT_DIR/summary.csv"
echo "pause_per_round,spin_rounds,run,QPS" > "$RESULT_DIR/raw.csv"

MC_PID=""

cleanup() {
    if [ -n "$MC_PID" ] && kill -0 "$MC_PID" 2>/dev/null; then
        kill "$MC_PID" 2>/dev/null
        wait "$MC_PID" 2>/dev/null
    fi
    MC_PID=""
}
trap cleanup EXIT

start_memcached() {
    local ppr=$1
    cleanup
    MEMCACHED_SPIN_ROUNDS="$SPIN_ROUNDS" \
    MEMCACHED_PAUSE_PER_ROUND="$ppr" \
        "$MEMCACHED_BIN" -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
    MC_PID=$!
    local i
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  spin_rounds=$SPIN_ROUNDS  pause_per_round=$ppr  total_pause_budget=$((SPIN_ROUNDS * ppr))"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2
    return 1
}

run_warmup() {
    "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true
}

run_measure() {
    local logfile=$1
    "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -t "$DURATION" \
        2>&1 | tee "$logfile"
}

extract_qps()    { grep -E "^Total QPS" "$1" | awk '{print $4}'; }
extract_avg_us() { grep -E "^read"      "$1" | awk '{print $2}'; }
extract_p99_us() { grep -E "^read"      "$1" | awk '{print $8}'; }

compute_stats() {
    echo "$@" | tr ' ' '\n' | awk '
    {
        vals[NR] = $1; sum += $1
        if (NR == 1 || $1 < mn) mn = $1
        if (NR == 1 || $1 > mx) mx = $1
    }
    END {
        n = NR; mean = sum / n
        for (i = 1; i <= n; i++) sq += (vals[i] - mean)^2
        sd = (n > 1) ? sqrt(sq / (n-1)) : 0
        for (i = 2; i <= n; i++) {
            key = vals[i]; j = i - 1
            while (j >= 1 && vals[j] > key) { vals[j+1] = vals[j]; j-- }
            vals[j+1] = key
        }
        med = (n % 2 == 1) ? vals[(n+1)/2] : (vals[n/2] + vals[n/2+1]) / 2
        cv  = (mean > 0) ? sd / mean * 100 : 0
        printf "%.1f %.1f %.1f %.1f %.1f %.2f", mean, med, sd, mn, mx, cv
    }'
}

echo "============================================================"
echo " memcached MySQL-like ut_delay spinlock sweep"
echo "============================================================"
echo " binary       : $MEMCACHED_BIN"
echo " mutilate     : $MUTILATE_BIN"
echo " mc_threads   : $MC_THREADS  ($(nproc) physical cores)"
echo " mut_threads  : $MUT_THREADS  connections: $MUT_CONNS"
echo " records      : $RECORDS  update_ratio: $UPDATE_RATIO"
echo " warmup       : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " SPIN_ROUNDS  : $SPIN_ROUNDS (fixed)"
echo " N values     : $PAUSE_PER_ROUND_VALUES"
echo " results      : $RESULT_DIR"
echo "============================================================"

for ppr in $PAUSE_PER_ROUND_VALUES; do
    total_budget=$((SPIN_ROUNDS * ppr))
    echo ""
    echo ">>> pause_per_round=$ppr  (spin_rounds=$SPIN_ROUNDS  total_pause_budget=$total_budget)"

    start_memcached "$ppr"

    echo "    warmup ${WARMUP_SEC}s ..."
    run_warmup

    qps_list=""
    last_avg=""
    last_p99=""

    for run_idx in $(seq 1 "$RUNS"); do
        logfile="$RESULT_DIR/run_N${ppr}_${run_idx}.log"
        run_measure "$logfile" > /dev/null
        qps=$(extract_qps "$logfile")
        last_avg=$(extract_avg_us "$logfile")
        last_p99=$(extract_p99_us "$logfile")
        printf "    run %d/%d: QPS=%.1f  avg=%sus  p99=%sus\n" \
            "$run_idx" "$RUNS" "$qps" "$last_avg" "$last_p99"
        qps_list="$qps_list $qps"
        echo "$ppr,$SPIN_ROUNDS,$run_idx,$qps" >> "$RESULT_DIR/raw.csv"
    done

    read mean_qps median_qps stddev_qps min_qps max_qps cv_pct \
        <<< "$(compute_stats $qps_list)"

    printf "    STATS: mean=%.1f  median=%.1f  sd=%.1f  cv=%.2f%%  [%.1f - %.1f]\n" \
        "$mean_qps" "$median_qps" "$stddev_qps" "$cv_pct" "$min_qps" "$max_qps"

    echo "$ppr,$SPIN_ROUNDS,$mean_qps,$median_qps,$stddev_qps,$min_qps,$max_qps,$cv_pct,$last_avg,$last_p99" \
        >> "$RESULT_DIR/summary.csv"

    cleanup
    sleep 1
done

echo ""
echo "============================================================"
echo " FINAL SUMMARY  (SPIN_ROUNDS=$SPIN_ROUNDS)"
echo "============================================================"
printf "%-16s %-10s %-12s %-12s %-10s %-8s\n" \
    "pause_per_round" "total_PAUSEs" "mean_QPS" "median_QPS" "stddev" "CV%"
echo "------------------------------------------------------------"
tail -n +2 "$RESULT_DIR/summary.csv" | while IFS=',' read -r ppr rounds mean med sd mn mx cv avg p99; do
    total=$((ppr * rounds))
    printf "%-16s %-10s %-12s %-12s %-10s %-8s\n" "$ppr" "$total" "$mean" "$med" "$sd" "$cv"
done

echo ""
echo "Full data: $RESULT_DIR/summary.csv"
echo "Raw runs : $RESULT_DIR/raw.csv"
