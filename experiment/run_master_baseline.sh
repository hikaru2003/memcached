#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   RESULT_DIR=experiment/results/ratio_sweep_YYYYMMDD_HHMMSS \
#     ./experiment/run_master_baseline.sh
#
# Parameters (env vars):
#   RESULT_DIR     - existing ratio_sweep result directory (REQUIRED)
#   MEMCACHED_BIN  - master branch memcached binary       (default: ./memcached_master)
#   MUTILATE_BIN   - path to mutilate binary              (default: ../mutilate/mutilate)
#   WARMUP_SEC     - warmup duration in seconds           (default: 10)
#   DURATION       - measurement duration in seconds      (default: 30)
#   RUNS           - runs per ratio                       (default: 3)
#   MC_THREADS     - memcached worker threads             (default: 32)
#   MUT_THREADS    - mutilate client threads              (default: 4)
#   MUT_CONNS      - mutilate connections per thread      (default: 4)
#   PORT           - memcached port                       (default: 11222)
#   PAUSE_VALUES   - space-separated pause counts to show in summary
#                    (default: auto-detected from first subdir's summary.md)
#   SKIP_MEASURE   - 1 = skip measurement, regenerate summary.md only
#                    (default: 0)
#
# What this does:
#   1. [SKIP_MEASURE=0] For each get{X}_set{Y} subdir, run master-branch memcached
#      and measure QPS (RUNS times). Save to RESULT_DIR/master_baseline/.
#   2. Regenerate RESULT_DIR/summary.md with master baseline column and
#      gain% values relative to master for each PAUSE value.
#
# Prerequisites:
#   - MEMCACHED_BIN built from master branch (no spinlock changes)
#   - mutilate binary at ../mutilate/mutilate (or set MUTILATE_BIN)

set -uo pipefail

RESULT_DIR="${RESULT_DIR:?RESULT_DIR is required}"
MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached_master}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
WARMUP_SEC="${WARMUP_SEC:-10}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-3}"
MC_THREADS="${MC_THREADS:-32}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-4}"
PORT="${PORT:-11222}"
PAUSE_VALUES="${PAUSE_VALUES:-}"
SKIP_MEASURE="${SKIP_MEASURE:-0}"
RECORDS=1

BASELINE_DIR="$RESULT_DIR/master_baseline"
mkdir -p "$BASELINE_DIR"

# enumerate subdirs in canonical ratio order
RATIO_DIRS=$(ls -d "$RESULT_DIR"/get*_set* 2>/dev/null | sort -t_ -k1,1V -k2,2V)

# auto-detect PAUSE_VALUES from first subdir's summary.md if not set
if [ -z "$PAUSE_VALUES" ]; then
    first_sub=$(echo "$RATIO_DIRS" | head -1)
    PAUSE_VALUES=$(grep "^| [0-9]" "$first_sub/summary.md" \
        | awk -F'|' '{gsub(/ /,"",$2); print $2}' | tr '\n' ' ' | sed 's/ $//')
    echo "[info] auto-detected PAUSE_VALUES: $PAUSE_VALUES"
fi

# ----------------------------------------------------------------
# measurement phase (skipped if SKIP_MEASURE=1)
# ----------------------------------------------------------------
declare -A master_qps

if [ "$SKIP_MEASURE" = "0" ]; then

    MC_PID=""
    cleanup() {
        if [ -n "$MC_PID" ] && kill -0 "$MC_PID" 2>/dev/null; then
            kill "$MC_PID" 2>/dev/null; wait "$MC_PID" 2>/dev/null
        fi
        MC_PID=""
    }
    trap cleanup EXIT

    start_memcached() {
        local update_ratio=$1; cleanup
        "$MEMCACHED_BIN" -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
        MC_PID=$!
        local i
        for i in $(seq 1 10); do
            sleep 0.5
            if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
                echo "[mc-master] PID=$MC_PID  update_ratio=$update_ratio  (port $PORT ready)"
                return 0
            fi
        done
        echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
    }

    run_warmup() {
        "$MUTILATE_BIN" -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$1" \
            -T "$MUT_THREADS" -c "$MUT_CONNS" -t "$WARMUP_SEC" > /dev/null 2>&1 || true
    }

    run_measure() {
        "$MUTILATE_BIN" -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$2" \
            -T "$MUT_THREADS" -c "$MUT_CONNS" -t "$DURATION" 2>&1 | tee "$1"
    }

    extract_qps()    { grep -E "^Total QPS" "$1" | awk '{print $4}'; }
    extract_avg_us() { grep -E "^read"      "$1" | awk '{print $2}'; }
    extract_p99_us() { grep -E "^read"      "$1" | awk '{print $8}'; }

    compute_stats() {
        echo "$@" | tr ' ' '\n' | awk '
        { vals[NR]=$1; sum+=$1; if(NR==1||$1<mn)mn=$1; if(NR==1||$1>mx)mx=$1 }
        END {
            n=NR; mean=sum/n
            for(i=1;i<=n;i++) sq+=(vals[i]-mean)^2
            sd=(n>1)?sqrt(sq/(n-1)):0
            for(i=2;i<=n;i++){key=vals[i];j=i-1;while(j>=1&&vals[j]>key){vals[j+1]=vals[j];j--};vals[j+1]=key}
            med=(n%2==1)?vals[(n+1)/2]:(vals[n/2]+vals[n/2+1])/2
            cv=(mean>0)?sd/mean*100:0
            printf "%.1f %.1f %.1f %.1f %.1f %.2f",mean,med,sd,mn,mx,cv
        }'
    }

    echo "============================================================"
    echo " master baseline measurement for ratio_sweep"
    echo "============================================================"
    echo " binary      : $MEMCACHED_BIN"
    echo " mc_threads  : $MC_THREADS  ($(nproc) physical cores)"
    echo " warmup      : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
    echo " result_dir  : $RESULT_DIR"
    echo "============================================================"

    {
        echo "# master branch baseline / t=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -r ${RECORDS} / n=${RUNS}"
        echo ""
        echo "| ratio | mean_QPS | median_QPS | stddev_QPS | cv_pct | n |"
        echo "|---|---|---|---|---|---|"
    } > "$BASELINE_DIR/summary.md"
    echo "ratio,run,QPS" > "$BASELINE_DIR/raw.csv"

    for subdir in $RATIO_DIRS; do
        subdir_name=$(basename "$subdir")
        set_pct=$(echo "$subdir_name" | sed 's/get[0-9]*_set//')
        update_ratio=$(awk "BEGIN { printf \"%.1f\", $set_pct / 100 }")

        echo ""; echo ">>> $subdir_name  (update_ratio=$update_ratio)"
        start_memcached "$update_ratio"
        echo "    warmup ${WARMUP_SEC}s ..."; run_warmup "$update_ratio"

        qps_list=""; last_avg=""; last_p99=""
        for run_idx in $(seq 1 "$RUNS"); do
            logfile="$BASELINE_DIR/run_${subdir_name}_${run_idx}.log"
            run_measure "$logfile" "$update_ratio" > /dev/null
            qps=$(extract_qps "$logfile")
            last_avg=$(extract_avg_us "$logfile"); last_p99=$(extract_p99_us "$logfile")
            printf "    run %d/%d: QPS=%.1f  avg=%sus  p99=%sus\n" \
                "$run_idx" "$RUNS" "$qps" "$last_avg" "$last_p99"
            qps_list="$qps_list $qps"
            echo "$subdir_name,$run_idx,$qps" >> "$BASELINE_DIR/raw.csv"
        done

        read mean_qps median_qps stddev_qps min_qps max_qps cv_pct \
            <<< "$(compute_stats $qps_list)"
        printf "    STATS: mean=%.1f  median=%.1f  sd=%.1f  cv=%.2f%%  [%.1f - %.1f]\n" \
            "$mean_qps" "$median_qps" "$stddev_qps" "$cv_pct" "$min_qps" "$max_qps"
        echo "| $subdir_name | $mean_qps | $median_qps | $stddev_qps | $cv_pct | $RUNS |" \
            >> "$BASELINE_DIR/summary.md"
        master_qps["$subdir_name"]="$mean_qps"
        cleanup; sleep 1
    done

else
    echo "[info] SKIP_MEASURE=1: loading existing master baseline from $BASELINE_DIR/summary.md"
    while IFS= read -r line; do
        key=$(echo "$line" | awk -F'|' '{gsub(/ /,"",$2); print $2}')
        val=$(echo "$line" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
        [ -n "$key" ] && master_qps["$key"]="$val"
    done < <(grep "^| get" "$BASELINE_DIR/summary.md")
fi

# ----------------------------------------------------------------
# regenerate top-level summary.md (dynamic PAUSE_VALUES)
# ----------------------------------------------------------------
{
    echo "# GET:SET ratio sweep — PAUSE effect vs master baseline"
    echo "# experiment/pause-spinlock / t=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -r ${RECORDS} / n=${RUNS}"
    echo ""

    # build header dynamically
    header="| ratio | master"
    sep="|---|---"
    for pc in $PAUSE_VALUES; do
        header="$header | pause=${pc} | gain_${pc}%"
        sep="$sep|---|---"
    done
    echo "${header} |"
    echo "${sep}|"

    for subdir in $RATIO_DIRS; do
        subdir_name=$(basename "$subdir")
        sub_summary="$subdir/summary.md"
        m="${master_qps[$subdir_name]:-0}"

        row="| $subdir_name | $m"
        for pc in $PAUSE_VALUES; do
            pval=$(grep "^| ${pc} " "$sub_summary" \
                | awk -F'|' '{gsub(/ /,"",$3); print $3}')
            gain=$(awk "BEGIN {
                if ($m > 0 && \"$pval\" != \"\")
                    printf \"%.1f\", ($pval - $m) / $m * 100
                else print \"N/A\"
            }")
            row="$row | $pval | ${gain}%"
        done
        echo "${row} |"
    done
} > "$RESULT_DIR/summary.md"

echo ""
echo "============================================================"
echo " UPDATED SUMMARY (gain% relative to master baseline)"
echo "============================================================"
cat "$RESULT_DIR/summary.md"
echo ""
echo "Master baseline : $BASELINE_DIR/summary.md"
echo "Full summary    : $RESULT_DIR/summary.md"
