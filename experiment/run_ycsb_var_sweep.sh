#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_ycsb_var_sweep.sh
#
# Parameters (env vars, all optional):
#   MEMCACHED_BIN      - path to memcached binary          (default: ./memcached)
#   YCSB_BIN           - path to YCSB bin/ycsb             (default: ../ycsb-0.17.0/bin/ycsb)
#   WORKLOAD_FILE      - YCSB workload properties file     (default: ./experiment/workloads/var_workload.dat)
#   WARMUP_SEC         - warmup duration in seconds        (default: 10)
#   DURATION           - measurement duration in seconds   (default: 30)
#   RUNS               - repeated measurements per N       (default: 5)
#   MC_THREADS         - memcached worker threads          (default: 32)
#   YCSB_THREADS       - YCSB client threads               (default: 16)
#   PORT               - memcached port                    (default: 11222)
#   SPIN_ROUNDS        - fixed (trylock+delay) cycles      (default: 30)
#   PAUSE_PER_ROUND_VALUES - space-separated N values to sweep
#                            (default: "0 1 2 3 5 7 10 15 20 30")
#
# Workload: Facebook VAR workload approximation
#   - 82% SET / 18% GET
#   - Zipf key distribution (s=1.107: top 10% keys = 90% requests)
#   - 100,000 key-value pairs, value size ~500B
#
# Output:
#   experiment/results/ycsb_var_sweep_YYYYMMDD_HHMMSS/
#     summary.md    - per-N statistics in Markdown table format
#     raw.csv       - all individual run OPS values
#     run_N<N>_<run>.log  - raw YCSB output per (N, run)
#
# Prerequisites:
#   - memcached built on experiment/mysql-like-utdelay branch
#   - YCSB 0.17.0 at ../ycsb-0.17.0/ (or set YCSB_BIN)
#   - Java 8+ installed

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached}"
YCSB_BIN="${YCSB_BIN:-../ycsb-0.17.0/bin/ycsb.sh}"
WORKLOAD_FILE="${WORKLOAD_FILE:-./experiment/workloads/var_workload.dat}"
WARMUP_SEC="${WARMUP_SEC:-10}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-5}"
MC_THREADS="${MC_THREADS:-32}"
YCSB_THREADS="${YCSB_THREADS:-16}"
PORT="${PORT:-11222}"
SPIN_ROUNDS="${SPIN_ROUNDS:-30}"
PAUSE_PER_ROUND_VALUES="${PAUSE_PER_ROUND_VALUES:-0 1 2 3 5 7 10 15 20 30}"

RESULT_DIR="experiment/results/ycsb_var_sweep_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULT_DIR"

{
    echo "# experiment/mysql-like-utdelay / spin_rounds=${SPIN_ROUNDS} / YCSB VAR (Zipf s=1.107, 82% SET, 100k keys, 500B) / t=${MC_THREADS} / ycsb_threads=${YCSB_THREADS} / n=${RUNS}"
    echo ""
    echo "| pause_per_round | mean_OPS | median_OPS | stddev_OPS | cv_pct | read_avg_us | update_avg_us | n |"
    echo "|---|---|---|---|---|---|---|---|"
} > "$RESULT_DIR/summary.md"
echo "pause_per_round,spin_rounds,run,OPS" > "$RESULT_DIR/raw.csv"

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
            echo "[mc] PID=$MC_PID  spin_rounds=$SPIN_ROUNDS  pause_per_round=$ppr"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2
    return 1
}

run_ycsb_load() {
    "$YCSB_BIN" load memcached -s \
        -P "$WORKLOAD_FILE" \
        -p "memcached.hosts=127.0.0.1:$PORT" \
        -threads "$YCSB_THREADS" \
        > /dev/null 2>&1 || true
}

run_ycsb_warmup() {
    "$YCSB_BIN" run memcached -s \
        -P "$WORKLOAD_FILE" \
        -p "memcached.hosts=127.0.0.1:$PORT" \
        -p "maxexecutiontime=$WARMUP_SEC" \
        -threads "$YCSB_THREADS" \
        > /dev/null 2>&1 || true
}

run_ycsb_measure() {
    local logfile=$1
    "$YCSB_BIN" run memcached -s \
        -P "$WORKLOAD_FILE" \
        -p "memcached.hosts=127.0.0.1:$PORT" \
        -p "maxexecutiontime=$DURATION" \
        -threads "$YCSB_THREADS" \
        2>&1 | tee "$logfile"
}

extract_ops()        { grep "^\[OVERALL\], Throughput"    "$1" | awk -F', ' '{print $3}'; }
extract_read_avg()   { grep "^\[READ\], AverageLatency"   "$1" | awk -F', ' '{print $3}'; }
extract_update_avg() { grep "^\[UPDATE\], AverageLatency" "$1" | awk -F', ' '{print $3}'; }

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
echo " memcached VAR workload (YCSB) sweep"
echo "============================================================"
echo " binary        : $MEMCACHED_BIN"
echo " ycsb          : $YCSB_BIN"
echo " workload      : $WORKLOAD_FILE"
echo " mc_threads    : $MC_THREADS  ($(nproc) physical cores)"
echo " ycsb_threads  : $YCSB_THREADS"
echo " warmup        : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " SPIN_ROUNDS   : $SPIN_ROUNDS (fixed)"
echo " N values      : $PAUSE_PER_ROUND_VALUES"
echo " results       : $RESULT_DIR"
echo "============================================================"

for ppr in $PAUSE_PER_ROUND_VALUES; do
    total_budget=$((SPIN_ROUNDS * ppr))
    echo ""
    echo ">>> pause_per_round=$ppr  (spin_rounds=$SPIN_ROUNDS  total_pause_budget=$total_budget)"

    start_memcached "$ppr"

    echo "    loading 100k keys ..."
    run_ycsb_load

    echo "    warmup ${WARMUP_SEC}s ..."
    run_ycsb_warmup

    ops_list=""
    last_read_avg=""
    last_update_avg=""

    for run_idx in $(seq 1 "$RUNS"); do
        logfile="$RESULT_DIR/run_N${ppr}_${run_idx}.log"
        run_ycsb_measure "$logfile" > /dev/null
        ops=$(extract_ops "$logfile")
        last_read_avg=$(extract_read_avg "$logfile")
        last_update_avg=$(extract_update_avg "$logfile")
        printf "    run %d/%d: OPS=%.1f  read_avg=%sus  update_avg=%sus\n" \
            "$run_idx" "$RUNS" "$ops" "$last_read_avg" "$last_update_avg"
        ops_list="$ops_list $ops"
        echo "$ppr,$SPIN_ROUNDS,$run_idx,$ops" >> "$RESULT_DIR/raw.csv"
    done

    read mean_ops median_ops stddev_ops min_ops max_ops cv_pct \
        <<< "$(compute_stats $ops_list)"

    printf "    STATS: mean=%.1f  median=%.1f  sd=%.1f  cv=%.2f%%  [%.1f - %.1f]\n" \
        "$mean_ops" "$median_ops" "$stddev_ops" "$cv_pct" "$min_ops" "$max_ops"

    echo "| $ppr | $mean_ops | $median_ops | $stddev_ops | $cv_pct | $last_read_avg | $last_update_avg | $RUNS |" \
        >> "$RESULT_DIR/summary.md"

    cleanup
    sleep 1
done

echo ""
echo "============================================================"
echo " FINAL SUMMARY  (SPIN_ROUNDS=$SPIN_ROUNDS, VAR workload)"
echo "============================================================"
printf "%-16s %-12s %-12s %-10s %-8s\n" \
    "pause_per_round" "mean_OPS" "median_OPS" "stddev" "CV%"
echo "------------------------------------------------------------"

grep "^| [0-9]" "$RESULT_DIR/summary.md" | awk -F'|' '{
    gsub(/ /,"",$2); gsub(/ /,"",$3); gsub(/ /,"",$5); gsub(/ /,"",$6)
    printf "%-16s %-12s %-12s %-10s %-8s\n", $2, $3, $4, $5, $6
}'

echo ""
echo "Full data: $RESULT_DIR/summary.md"
echo "Raw runs : $RESULT_DIR/raw.csv"
