#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_pause_sweep.sh
#
# Parameters (env vars, all optional):
#   MEMCACHED_BIN  - path to memcached binary                  (default: ./memcached)
#   MUTILATE_BIN   - path to mutilate binary                   (default: ../mutilate/mutilate)
#   WARMUP_SEC     - warmup duration in seconds per run        (default: 10)
#   DURATION       - measurement duration in seconds per run   (default: 30)
#   RUNS           - number of repeated measurements per PAUSE (default: 5)
#   MC_THREADS     - memcached worker threads                  (default: 32)
#   MUT_THREADS    - mutilate client threads                   (default: 4)
#   MUT_CONNS      - mutilate connections per thread           (default: 4)
#   RECORDS        - key range (1 = single-slot contention)    (default: 1)
#   UPDATE_RATIO   - set:total ratio 0.0-1.0                   (default: 0.5)
#   PORT           - memcached port                            (default: 11222)
#   PAUSE_VALUES   - space-separated PAUSE_COUNT list
#                    (default: "0 10 20 30 40 50 60 70 80 90 100")
#
# Output:
#   experiment/results/pause_sweep_YYYYMMDD_HHMMSS/
#     summary.md           - per-PAUSE statistics in Markdown table format
#     raw.csv              - all individual run QPS values
#     run_<PAUSE>_<N>.log  - raw mutilate output per (PAUSE, run)
#
# Prerequisites:
#   - memcached built on experiment/pause-spinlock branch (spinlock.h + slabs.c)
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
PAUSE_VALUES="${PAUSE_VALUES:-0 10 20 30 40 50 60 70 80 90 100}"

RESULT_DIR="experiment/results/pause_sweep_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULT_DIR"

{
    echo "# experiment/pause-spinlock / t=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -r ${RECORDS} -u ${UPDATE_RATIO} / n=${RUNS}"
    echo ""
    echo "| pause_count | mean_QPS | median_QPS | stddev_QPS | cv_pct | read_avg_us | read_p99_us | n |"
    echo "|---|---|---|---|---|---|---|---|"
} > "$RESULT_DIR/summary.md"
echo "PAUSE_COUNT,run,QPS" > "$RESULT_DIR/raw.csv"

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
    local pause_count=$1
    cleanup
    MEMCACHED_PAUSE_COUNT=$pause_count \
        "$MEMCACHED_BIN" -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
    MC_PID=$!
    # wait until port is open (up to 5s)
    local i
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  PAUSE_COUNT=$pause_count  (port $PORT ready)"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2
    return 1
}

run_warmup() {
    "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" \
        -r "$RECORDS" \
        -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" \
        -c "$MUT_CONNS" \
        -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true
}

run_measure() {
    local logfile=$1
    "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" \
        -r "$RECORDS" \
        -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" \
        -c "$MUT_CONNS" \
        -t "$DURATION" \
        2>&1 | tee "$logfile"
}

extract_qps() {
    grep -E "^Total QPS" "$1" | awk '{print $4}'
}
extract_avg_us() {
    grep -E "^read" "$1" | awk '{print $2}'
}
extract_p99_us() {
    grep -E "^read" "$1" | awk '{print $8}'
}

# awk-based statistics (mean, median, stddev, min, max, CV)
compute_stats() {
    # args: space-separated QPS values
    echo "$@" | tr ' ' '\n' | awk '
    {
        vals[NR] = $1
        sum += $1
        if (NR == 1 || $1 < mn) mn = $1
        if (NR == 1 || $1 > mx) mx = $1
    }
    END {
        n = NR
        mean = sum / n
        # stddev
        for (i = 1; i <= n; i++) sq += (vals[i] - mean)^2
        sd = (n > 1) ? sqrt(sq / (n-1)) : 0
        # median (sort by insertion)
        for (i = 2; i <= n; i++) {
            key = vals[i]; j = i - 1
            while (j >= 1 && vals[j] > key) { vals[j+1] = vals[j]; j-- }
            vals[j+1] = key
        }
        med = (n % 2 == 1) ? vals[(n+1)/2] : (vals[n/2] + vals[n/2+1]) / 2
        cv = (mean > 0) ? sd / mean * 100 : 0
        printf "%.1f %.1f %.1f %.1f %.1f %.2f", mean, med, sd, mn, mx, cv
    }'
}

echo "============================================================"
echo " memcached PAUSE sweep experiment"
echo "============================================================"
echo " binary     : $MEMCACHED_BIN"
echo " mutilate   : $MUTILATE_BIN"
echo " mc_threads : $MC_THREADS  ($(nproc) physical cores)"
echo " mut_threads: $MUT_THREADS  connections: $MUT_CONNS"
echo " records    : $RECORDS  update_ratio: $UPDATE_RATIO"
echo " warmup     : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " PAUSE list : $PAUSE_VALUES"
echo " results    : $RESULT_DIR"
echo "============================================================"

for pause_count in $PAUSE_VALUES; do
    echo ""
    echo ">>> PAUSE_COUNT=$pause_count"

    start_memcached "$pause_count"

    echo "    warmup ${WARMUP_SEC}s ..."
    run_warmup

    qps_list=""
    last_avg=""
    last_p99=""

    for run_idx in $(seq 1 "$RUNS"); do
        logfile="$RESULT_DIR/run_${pause_count}_${run_idx}.log"
        run_measure "$logfile" > /dev/null
        qps=$(extract_qps "$logfile")
        last_avg=$(extract_avg_us "$logfile")
        last_p99=$(extract_p99_us "$logfile")
        printf "    run %d/%d: QPS=%.1f  avg=%sus  p99=%sus\n" \
            "$run_idx" "$RUNS" "$qps" "$last_avg" "$last_p99"
        qps_list="$qps_list $qps"
        echo "$pause_count,$run_idx,$qps" >> "$RESULT_DIR/raw.csv"
    done

    read mean_qps median_qps stddev_qps min_qps max_qps cv_pct \
        <<< "$(compute_stats $qps_list)"

    printf "    STATS: mean=%.1f  median=%.1f  sd=%.1f  cv=%.2f%%  [%.1f - %.1f]\n" \
        "$mean_qps" "$median_qps" "$stddev_qps" "$cv_pct" "$min_qps" "$max_qps"

    echo "| $pause_count | $mean_qps | $median_qps | $stddev_qps | $cv_pct | $last_avg | $last_p99 | $RUNS |" \
        >> "$RESULT_DIR/summary.md"

    cleanup
    sleep 1
done

echo ""
echo "============================================================"
echo " FINAL SUMMARY"
echo "============================================================"
printf "%-12s %-12s %-12s %-10s %-8s\n" \
    "PAUSE_COUNT" "mean_QPS" "median_QPS" "stddev" "CV%"
echo "------------------------------------------------------------"

grep "^| [0-9]" "$RESULT_DIR/summary.md" | awk -F'|' '{
    gsub(/ /,"",$2); gsub(/ /,"",$3); gsub(/ /,"",$5); gsub(/ /,"",$6)
    printf "%-12s %-12s %-12s %-10s %-8s\n", $2, $3, $4, $5, $6
}'

echo ""
echo "Full data: $RESULT_DIR/summary.md"
echo "Raw runs : $RESULT_DIR/raw.csv"
