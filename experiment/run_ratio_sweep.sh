#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_ratio_sweep.sh
#
# Parameters (env vars, all optional):
#   MEMCACHED_BIN        - path to memcached binary                  (default: ./memcached)
#   MUTILATE_BIN         - path to mutilate binary                   (default: ../mutilate/mutilate)
#   WARMUP_SEC           - warmup duration in seconds per run        (default: 10)
#   DURATION             - measurement duration in seconds per run   (default: 30)
#   RUNS                 - number of repeated measurements per PAUSE (default: 3)
#   MC_THREADS           - memcached worker threads                  (default: 32)
#   MUT_THREADS          - mutilate client threads                   (default: 4)
#   MUT_CONNS            - mutilate connections per thread           (default: 4)
#   PORT                 - memcached port                            (default: 11222)
#   PAUSE_VALUES         - space-separated PAUSE_COUNT list          (default: "0 10 40 100")
#   UPDATE_RATIO_VALUES  - space-separated update_ratio list         (default: "0.0 0.1 0.3 0.5 0.7 0.9 1.0")
#
# Experiment: fix -r 1 (single key, maximum item_lock contention),
#             vary GET:SET ratio to verify PAUSE effectiveness is
#             independent of ratio (driven by item_lock contention).
#
# Output:
#   experiment/results/pause_spinlock_ratio_sweep_t{MC}_T{MT}c{MC}_r{REC}/
#     run_info.md                    <- 実験日時・コミット・パラメータ
#     summary.md                     <- cross-ratio PAUSE gain% table
#     get{X}_set{Y}/
#       README.md                    <- experiment conditions memo
#       summary.md                   <- per-PAUSE QPS statistics
#       raw.csv
#       run_P{pause}_{run}.log
#
# Prerequisites:
#   - memcached built on experiment/pause-spinlock branch
#   - mutilate binary at ../mutilate/mutilate (or set MUTILATE_BIN)

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
WARMUP_SEC="${WARMUP_SEC:-10}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-3}"
MC_THREADS="${MC_THREADS:-8}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-4}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"
PAUSE_VALUES="${PAUSE_VALUES:-0 10 40 100}"
UPDATE_RATIO_VALUES="${UPDATE_RATIO_VALUES:-0.0 0.1 0.3 0.5 0.7 0.9 1.0}"
RECORDS=1

RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
_BASE="experiment/results/pause_spinlock_ratio_sweep_t${MC_THREADS}_T${MUT_THREADS}c${MUT_CONNS}_r${RECORDS}"
RESULT_DIR="$_BASE"
_i=2; while [ -d "$RESULT_DIR" ]; do RESULT_DIR="${_BASE}_run${_i}"; _i=$((_i+1)); done
mkdir -p "$RESULT_DIR"
{
    echo "# Run info"
    echo "- date: ${RUN_DATE}"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- mc_threads: $MC_THREADS / mut_threads: $MUT_THREADS / mut_conns: $MUT_CONNS"
    echo "- records: $RECORDS / warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- pause_values: $PAUSE_VALUES"
    echo "- update_ratio_values: $UPDATE_RATIO_VALUES"
} > "$RESULT_DIR/run_info.md"

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
        taskset -c "$MC_CPUS" "$MEMCACHED_BIN" -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
    MC_PID=$!
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
    local update_ratio=$1
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$update_ratio" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true
}

run_measure() {
    local logfile=$1 update_ratio=$2
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$update_ratio" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -t "$DURATION" \
        2>&1 | tee "$logfile"
}

extract_qps()       { grep -E "^Total QPS" "$1" | awk '{print $4}'; }
extract_avg_us()    { grep -E "^read"   "$1" | awk '{print $2}'; }
extract_p99_us()    { grep -E "^read"   "$1" | awk '{print $8}'; }
extract_w_avg_us()  { grep -E "^update" "$1" | awk '{print $2}'; }
extract_w_p99_us()  { grep -E "^update" "$1" | awk '{print $8}'; }

compute_mean() {
    echo "$@" | tr ' ' '\n' | awk 'NF{s+=$1;c++} END{printf "%.1f", c>0 ? s/c : 0}'
}

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

# ratio_results[subdir]="pause0_mean pause10_mean pause40_mean pause100_mean"
declare -A ratio_pause0 ratio_pause10 ratio_pause40 ratio_pause100

echo "============================================================"
echo " memcached GET:SET ratio sweep (PAUSE effect verification)"
echo "============================================================"
echo " binary      : $MEMCACHED_BIN"
echo " mutilate    : $MUTILATE_BIN"
echo " mc_threads  : $MC_THREADS  ($(nproc) physical cores)"
echo " mut_threads : $MUT_THREADS  connections: $MUT_CONNS"
echo " records     : $RECORDS (single key, max item_lock contention)"
echo " warmup      : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " PAUSE values: $PAUSE_VALUES"
echo " ratio values: $UPDATE_RATIO_VALUES"
echo " results     : $RESULT_DIR"
echo "============================================================"

for update_ratio in $UPDATE_RATIO_VALUES; do
    # compute integer percentages (awk for float arithmetic)
    set_pct=$(awk "BEGIN { printf \"%d\", $update_ratio * 100 }")
    get_pct=$((100 - set_pct))
    subdir_name="get${get_pct}_set${set_pct}"
    subdir="$RESULT_DIR/$subdir_name"
    mkdir -p "$subdir"

    echo ""
    echo "============================================================"
    echo " ratio: $subdir_name  (update_ratio=$update_ratio)"
    echo "============================================================"

    # README.md
    cat > "$subdir/README.md" << EOF
# GET:SET ratio sweep — ${subdir_name}

- Branch: experiment/pause-spinlock
- PAUSE values tested: $PAUSE_VALUES
- update_ratio: ${update_ratio} (${set_pct}% SET / ${get_pct}% GET)
- key range: -r 1 (single key, maximum item_lock contention)
- mc_threads: ${MC_THREADS} / mut_threads: ${MUT_THREADS} / connections: ${MUT_CONNS}
- runs per pause: ${RUNS}
- date: ${TIMESTAMP}
EOF

    # sub summary.md header
    {
        echo "# experiment/pause-spinlock / ${subdir_name} / t=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -r ${RECORDS} / n=${RUNS}"
        echo ""
        echo "| pause_count | mean_QPS | median_QPS | stddev_QPS | cv_pct | read_avg_us | read_p99_us | write_avg_us | write_p99_us | n |"
        echo "|---|---|---|---|---|---|---|---|---|---|"
    } > "$subdir/summary.md"
    echo "pause_count,run,QPS" > "$subdir/raw.csv"

    for pause_count in $PAUSE_VALUES; do
        echo ""
        echo "  >>> PAUSE_COUNT=$pause_count  ratio=$subdir_name"

        start_memcached "$pause_count"

        echo "      warmup ${WARMUP_SEC}s ..."
        run_warmup "$update_ratio"

        qps_list=""
        r_avg_list="" r_p99_list=""
        w_avg_list="" w_p99_list=""

        for run_idx in $(seq 1 "$RUNS"); do
            logfile="$subdir/run_P${pause_count}_${run_idx}.log"
            run_measure "$logfile" "$update_ratio" > /dev/null
            qps=$(extract_qps "$logfile")
            r_avg=$(extract_avg_us   "$logfile")
            r_p99=$(extract_p99_us   "$logfile")
            w_avg=$(extract_w_avg_us "$logfile")
            w_p99=$(extract_w_p99_us "$logfile")
            printf "      run %d/%d: QPS=%.1f  r_avg=%sus  r_p99=%sus  w_avg=%sus  w_p99=%sus\n" \
                "$run_idx" "$RUNS" "$qps" "$r_avg" "$r_p99" "$w_avg" "$w_p99"
            qps_list="$qps_list $qps"
            r_avg_list="$r_avg_list $r_avg"
            r_p99_list="$r_p99_list $r_p99"
            w_avg_list="$w_avg_list $w_avg"
            w_p99_list="$w_p99_list $w_p99"
            echo "$pause_count,$run_idx,$qps" >> "$subdir/raw.csv"
        done

        read mean_qps median_qps stddev_qps min_qps max_qps cv_pct \
            <<< "$(compute_stats $qps_list)"
        mean_r_avg=$(compute_mean $r_avg_list)
        mean_r_p99=$(compute_mean $r_p99_list)
        mean_w_avg=$(compute_mean $w_avg_list)
        mean_w_p99=$(compute_mean $w_p99_list)

        printf "      STATS: mean=%.1f  median=%.1f  sd=%.1f  cv=%.2f%%  [%.1f - %.1f]\n" \
            "$mean_qps" "$median_qps" "$stddev_qps" "$cv_pct" "$min_qps" "$max_qps"

        echo "| $pause_count | $mean_qps | $median_qps | $stddev_qps | $cv_pct | $mean_r_avg | $mean_r_p99 | $mean_w_avg | $mean_w_p99 | $RUNS |" \
            >> "$subdir/summary.md"

        # store for cross-ratio table
        case "$pause_count" in
            0)   ratio_pause0["$subdir_name"]="$mean_qps" ;;
            10)  ratio_pause10["$subdir_name"]="$mean_qps" ;;
            40)  ratio_pause40["$subdir_name"]="$mean_qps" ;;
            100) ratio_pause100["$subdir_name"]="$mean_qps" ;;
        esac

        cleanup
        sleep 1
    done
done

# Top-level summary.md
{
    echo "# GET:SET ratio sweep — PAUSE effect comparison"
    echo "# experiment/pause-spinlock / t=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -r ${RECORDS} / n=${RUNS}"
    echo ""
    echo "| ratio | pause=0 | pause=10 | gain_10% | pause=40 | gain_40% | pause=100 | gain_100% |"
    echo "|---|---|---|---|---|---|---|---|"

    for update_ratio in $UPDATE_RATIO_VALUES; do
        set_pct=$(awk "BEGIN { printf \"%d\", $update_ratio * 100 }")
        get_pct=$((100 - set_pct))
        key="get${get_pct}_set${set_pct}"

        p0="${ratio_pause0[$key]:-0}"
        p10="${ratio_pause10[$key]:-0}"
        p40="${ratio_pause40[$key]:-0}"
        p100="${ratio_pause100[$key]:-0}"

        gain10=$(awk  "BEGIN { if ($p0 > 0) printf \"%.1f\", ($p10  - $p0) / $p0 * 100; else print \"N/A\" }")
        gain40=$(awk  "BEGIN { if ($p0 > 0) printf \"%.1f\", ($p40  - $p0) / $p0 * 100; else print \"N/A\" }")
        gain100=$(awk "BEGIN { if ($p0 > 0) printf \"%.1f\", ($p100 - $p0) / $p0 * 100; else print \"N/A\" }")

        echo "| $key | $p0 | $p10 | ${gain10}% | $p40 | ${gain40}% | $p100 | ${gain100}% |"
    done
} > "$RESULT_DIR/summary.md"

echo ""
echo "============================================================"
echo " FINAL SUMMARY"
echo "============================================================"
cat "$RESULT_DIR/summary.md"
echo ""
echo "Full data: $RESULT_DIR/summary.md"
