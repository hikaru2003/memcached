#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   git checkout debug/futex-count -- memcached_debug_futex
#   ./experiment/run_futex_sweep_fine.sh
#
# Description:
#   memcached_debug_futex を用いて PAUSE 値ごとの futex fallback 回数を計測する。
#   get:set = 50:50 / -r 1 (single key) 固定。PAUSE を 10 刻みでスイープし、
#   QPS と futex_per_op の遷移を可視化するためのデータを取得する。
#   SIGUSR2 でスレッドごとの spinlock_futex_count を集計・リセットする。
#
# Parameters (env vars):
#   FUTEX_BIN    - debug バイナリ      (default: ./memcached_debug_futex)
#   MUTILATE_BIN - mutilate バイナリ   (default: ../mutilate/mutilate)
#   PAUSE_VALUES - PAUSE_COUNT sweep   (default: "0 10 20 30 40 50 60 70 80 90 100")
#   MC_THREADS   - memcached threads   (default: 4)
#   MUT_THREADS  - mutilate threads    (default: 4)
#   MUT_CONNS    - conns per thread    (default: 1)
#   DEPTH        - pipeline depth (-d) (default: 32)
#   RECORDS      - key range (-r)      (default: 1)
#   UPDATE_RATIO - SET fraction (-u)   (default: 0.5)
#   WARMUP_SEC   - warmup seconds      (default: 60)
#   DURATION     - measure seconds     (default: 30)
#   RUNS         - runs per pause      (default: 3)
#   PORT         - memcached port      (default: 11222)
#   MC_CPUS      - CPU affinity mc     (default: 0-3)
#   WL_CPUS      - CPU affinity mut    (default: 4-7)
#
# Output:
#   experiment/results/futex_sweep_fine_YYYYMMDD_HHMMSS/
#     run_info.md   - 実験パラメータ
#     mc_stderr.log - memcached stderr（SPINLOCK_FUTEX_COUNT 行を含む）
#     raw.csv       - pause_count,run,QPS,futex_count,futex_per_sec,futex_per_op
#     raw/          - mutilate ログ (run_P{pause}_{run}.log)
#     summary.md    - PAUSE 値別 QPS / futex_per_op テーブル
#
# Prerequisites:
#   - git checkout debug/futex-count -- memcached_debug_futex
#   - mutilate binary at ../mutilate/mutilate (or set MUTILATE_BIN)

set -uo pipefail

FUTEX_BIN="${FUTEX_BIN:-./memcached_debug_futex}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
MC_THREADS="${MC_THREADS:-4}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-1}"
DEPTH="${DEPTH:-32}"
PAUSE_VALUES="${PAUSE_VALUES:-0 10 20 30 40 50 60 70 80 90 100}"
UPDATE_RATIO="${UPDATE_RATIO:-0.5}"
RECORDS="${RECORDS:-1}"
WARMUP_SEC="${WARMUP_SEC:-60}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-3}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"

TOTAL_CONNS=$(( MUT_THREADS * MUT_CONNS ))
RUN_DATE=$(date '+%Y%m%d_%H%M%S')
RESULT_DIR="experiment/results/futex_sweep_fine_${RUN_DATE}"
mkdir -p "$RESULT_DIR/raw"

MC_STDERR_LOG="$RESULT_DIR/mc_stderr.log"

n_pause=$(echo "$PAUSE_VALUES" | wc -w)
est_sec=$(( n_pause * (WARMUP_SEC + DURATION * RUNS) ))
est_min=$(( est_sec / 60 ))

{
    echo "# Run info (futex sweep fine)"
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- binary: $FUTEX_BIN"
    echo "- mc_threads: $MC_THREADS (cpus: $MC_CPUS)"
    echo "- mut: -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH (total_conns=$TOTAL_CONNS)"
    echo "- update_ratio: $UPDATE_RATIO / records: $RECORDS"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- pause_values: $PAUSE_VALUES"
    echo "- est_time: ~${est_min} min"
} > "$RESULT_DIR/run_info.md"

MC_PID=""
cleanup() {
    if [ -n "$MC_PID" ] && kill -0 "$MC_PID" 2>/dev/null; then
        kill "$MC_PID" 2>/dev/null; wait "$MC_PID" 2>/dev/null
    fi
    MC_PID=""
}
trap cleanup EXIT

start_memcached() {
    local pause=$1; cleanup
    > "$MC_STDERR_LOG"
    MEMCACHED_PAUSE_COUNT=$pause \
        taskset -c "$MC_CPUS" "$FUTEX_BIN" -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody \
        2>>"$MC_STDERR_LOG" &
    MC_PID=$!
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  pause=$pause  (port $PORT ready)"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

run_mutilate() {
    local logfile=$1
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$DURATION" \
        2>&1 | tee "$logfile"
}

warmup() {
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true
}

read_futex_count() {
    kill -USR2 "$MC_PID"
    sleep 0.5
    grep "SPINLOCK_FUTEX_COUNT:" "$MC_STDERR_LOG" | tail -1 | awk '{print $2}'
}

extract_qps() { grep -E "^Total QPS" "$1" | awk '{print $4}'; }

compute_stats() {
    echo "$@" | tr ' ' '\n' | awk '
    { vals[NR]=$1; sum+=$1 }
    END {
        n=NR; mean=sum/n
        for(i=1;i<=n;i++) sq+=(vals[i]-mean)^2
        sd=(n>1)?sqrt(sq/(n-1)):0
        for(i=2;i<=n;i++){key=vals[i];j=i-1;while(j>=1&&vals[j]>key){vals[j+1]=vals[j];j--};vals[j+1]=key}
        med=(n%2==1)?vals[(n+1)/2]:(vals[n/2]+vals[n/2+1])/2
        cv=(mean>0)?sd/mean*100:0
        printf "%.4f %.4f %.4f %.2f",mean,med,sd,cv
    }'
}

echo "============================================================"
echo " futex sweep fine  (get:set=50:50 / -r 1)"
echo "============================================================"
echo " binary   : $FUTEX_BIN"
echo " mc       : -t $MC_THREADS  cpus: $MC_CPUS"
echo " mutilate : -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH (total_conns=$TOTAL_CONNS)"
echo " ratio    : -u $UPDATE_RATIO  -r $RECORDS"
echo " warmup   : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " pause    : $PAUSE_VALUES"
echo " est      : ~${est_min} min"
echo " results  : $RESULT_DIR"
echo "============================================================"

echo "pause_count,run,QPS,futex_count,futex_per_sec,futex_per_op" > "$RESULT_DIR/raw.csv"

{
    echo "# futex sweep fine / memcached_debug_futex / mc=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -d ${DEPTH} -r ${RECORDS} -u ${UPDATE_RATIO} / n=${RUNS}"
    echo ""
    echo "futex_per_op = futex_count / (QPS x DURATION)"
    echo "小さいほどスピンでロック取得 (futex fallback が少ない)"
    echo ""
    echo "| pause_count | mean_QPS | cv_qps% | mean_futex_per_op | cv_futex% | n |"
    echo "|---|---|---|---|---|---|"
} > "$RESULT_DIR/summary.md"

for pause_count in $PAUSE_VALUES; do
    echo ""
    echo ">>> PAUSE_COUNT=$pause_count"
    start_memcached "$pause_count"

    echo "    warmup ${WARMUP_SEC}s ..."
    warmup

    echo "    [USR2] reset after warmup"
    kill -USR2 "$MC_PID"; sleep 0.5

    qps_list="" futex_per_op_list=""
    for run_idx in $(seq 1 "$RUNS"); do
        raw_log="$RESULT_DIR/raw/run_P${pause_count}_${run_idx}.log"
        run_mutilate "$raw_log" > /dev/null

        qps=$(extract_qps "$raw_log")
        futex_count=$(read_futex_count)
        futex_per_sec=$(awk "BEGIN { printf \"%.3f\", ${futex_count:-0} / $DURATION }")
        futex_per_op=$(awk "BEGIN { q=${qps:-0}*$DURATION; printf \"%.6f\", (q>0) ? ${futex_count:-0}/q : 0 }")

        printf "    run %d/%d: QPS=%.0f  futex=%s  futex/op=%.4f\n" \
            "$run_idx" "$RUNS" "${qps:-0}" "${futex_count:-0}" "$futex_per_op"

        qps_list="$qps_list ${qps:-0}"
        futex_per_op_list="$futex_per_op_list $futex_per_op"
        echo "$pause_count,$run_idx,${qps:-0},${futex_count:-0},$futex_per_sec,$futex_per_op" >> "$RESULT_DIR/raw.csv"
    done

    read mean_qps _ _ cv_qps <<< "$(compute_stats $qps_list)"
    read mean_futex _ _ cv_futex <<< "$(compute_stats $futex_per_op_list)"

    printf "    STATS: mean_QPS=%.0f  cv=%.2f%%  mean_futex/op=%.4f  cv=%.2f%%\n" \
        "$mean_qps" "$cv_qps" "$mean_futex" "$cv_futex"

    echo "| $pause_count | $mean_qps | $cv_qps | $mean_futex | $cv_futex | $RUNS |" \
        >> "$RESULT_DIR/summary.md"

    cleanup; sleep 1
done

echo ""
echo "============================================================"
echo " FINAL SUMMARY"
echo "============================================================"
cat "$RESULT_DIR/summary.md"
echo ""
echo "Results: $RESULT_DIR"
