#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_utdelay_sweep.sh
#
# Description:
#   MySQL InnoDB ut_delay 型スピンロック（pause_per_round sweep）のQPS計測。
#   [trylock -> cpu_relax x N] x SPIN_ROUNDS -> mutex_lock
#   N=PAUSE_PER_ROUND_VALUES で sweep し、pause-spinlock との比較を行う。
#
# Parameters (env vars):
#   MEMCACHED_BIN          - memcached バイナリ (default: ./memcached)
#   MUTILATE_BIN           - mutilate バイナリ  (default: ../mutilate/mutilate)
#   MC_THREADS             - memcached ワーカースレッド数  (default: 4)
#   MUT_THREADS            - mutilate クライアントスレッド数 (default: 4)
#   MUT_CONNS              - mutilate コネクション/スレッド  (default: 1)
#   DEPTH                  - mutilate pipeline depth (-d)    (default: 32)
#   RECORDS                - key range (-r)                  (default: 1)
#   UPDATE_RATIO           - SET 割合 (-u)                   (default: 0.5)
#   WARMUP_SEC             - warmup 秒数                    (default: 180)
#   DURATION               - 計測秒数                       (default: 60)
#   RUNS                   - 各 N のラン数                   (default: 10)
#   SPIN_ROUNDS            - trylock 試行回数（固定）         (default: 30)
#   PAUSE_PER_ROUND_VALUES - N sweep 値                     (default: "1 2 3 4 5")
#   PORT                   - memcached ポート               (default: 11222)
#   MC_CPUS                - memcached CPU affinity         (default: 0-3)
#   WL_CPUS                - mutilate CPU affinity          (default: 4-7)
#
# Output:
#   experiment/results/utdelay_sweep_YYYYMMDD_HHMMSS/
#     run_info.md    - 実験パラメータ
#     summary.md     - N別 QPS 統計テーブル
#     raw.csv        - 全ランの生データ
#     raw/           - mutilate ログ
#
# Prerequisites:
#   - ./memcached: experiment/mysql-like-utdelay ブランチのビルド
#   - mutilate binary at ../mutilate/mutilate (or set MUTILATE_BIN)

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
MC_THREADS="${MC_THREADS:-4}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-1}"
DEPTH="${DEPTH:-32}"
RECORDS="${RECORDS:-1}"
UPDATE_RATIO="${UPDATE_RATIO:-0.5}"
WARMUP_SEC="${WARMUP_SEC:-180}"
DURATION="${DURATION:-60}"
RUNS="${RUNS:-10}"
SPIN_ROUNDS="${SPIN_ROUNDS:-30}"
PAUSE_PER_ROUND_VALUES="${PAUSE_PER_ROUND_VALUES:-1 2 3 4 5}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"

RUN_DATE=$(date '+%Y%m%d_%H%M%S')
RESULT_DIR="experiment/results/utdelay_sweep_${RUN_DATE}"
mkdir -p "$RESULT_DIR/raw"

n_vals=$(echo "$PAUSE_PER_ROUND_VALUES" | wc -w)
est_sec=$(( n_vals * (WARMUP_SEC + DURATION * RUNS) ))
est_min=$(( est_sec / 60 ))

{
    echo "# Run info (utdelay sweep)"
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- binary: $MEMCACHED_BIN"
    echo "- mc_threads: $MC_THREADS (cpus: $MC_CPUS)"
    echo "- mut: -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- spin_rounds: $SPIN_ROUNDS (fixed)"
    echo "- pause_per_round values: $PAUSE_PER_ROUND_VALUES"
    echo "- est_time: ~${est_min} min"
} > "$RESULT_DIR/run_info.md"

{
    echo "# utdelay sweep / mc=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -d ${DEPTH} -r ${RECORDS} -u ${UPDATE_RATIO} / n=${RUNS}"
    echo ""
    echo "spinlock: [trylock -> PAUSE x N] x SPIN_ROUNDS=${SPIN_ROUNDS} -> mutex_lock"
    echo ""
    echo "| pause_per_round | total_pause_budget | mean_QPS | median_QPS | stddev | cv% | n |"
    echo "|---|---|---|---|---|---|---|"
} > "$RESULT_DIR/summary.md"

echo "pause_per_round,spin_rounds,total_pause_budget,run,QPS,r_avg_us,r_p99_us,w_avg_us,w_p99_us" \
    > "$RESULT_DIR/raw.csv"

MC_PID=""
cleanup() {
    if [ -n "$MC_PID" ] && kill -0 "$MC_PID" 2>/dev/null; then
        kill "$MC_PID" 2>/dev/null; wait "$MC_PID" 2>/dev/null
    fi
    MC_PID=""
}
trap cleanup EXIT

start_memcached() {
    local ppr=$1
    cleanup
    MEMCACHED_SPIN_ROUNDS="$SPIN_ROUNDS" \
    MEMCACHED_PAUSE_PER_ROUND="$ppr" \
        taskset -c "$MC_CPUS" "$MEMCACHED_BIN" \
        -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
    MC_PID=$!
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  spin_rounds=$SPIN_ROUNDS  pause_per_round=$ppr  total_budget=$((SPIN_ROUNDS * ppr))"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

extract_qps()    { grep -E "^Total QPS" "$1" | awk '{print $4}'; }
extract_r_avg()  { grep -E "^read"   "$1" | awk '{print $2}'; }
extract_r_p99()  { grep -E "^read"   "$1" | awk '{print $9}'; }
extract_w_avg()  { grep -E "^update" "$1" | awk '{print $2}'; }
extract_w_p99()  { grep -E "^update" "$1" | awk '{print $9}'; }

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
        printf "%.1f %.1f %.1f %.2f",mean,med,sd,cv
    }'
}

echo "============================================================"
echo " memcached MySQL-like ut_delay spinlock sweep"
echo "============================================================"
echo " binary      : $MEMCACHED_BIN"
echo " mc_threads  : $MC_THREADS  cpus: $MC_CPUS"
echo " mut         : -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
echo " warmup      : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " SPIN_ROUNDS : $SPIN_ROUNDS (fixed)"
echo " N values    : $PAUSE_PER_ROUND_VALUES"
echo " est_time    : ~${est_min} min"
echo " results     : $RESULT_DIR"
echo "============================================================"

for ppr in $PAUSE_PER_ROUND_VALUES; do
    total_budget=$(( SPIN_ROUNDS * ppr ))
    echo ""
    echo "=============================="
    echo " pause_per_round=$ppr  (total_pause_budget=$total_budget)"
    echo "=============================="

    start_memcached "$ppr"

    echo "    warmup ${WARMUP_SEC}s ..."
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true

    qps_list="" r_avg_list="" r_p99_list="" w_avg_list="" w_p99_list=""

    for run_idx in $(seq 1 "$RUNS"); do
        logfile="$RESULT_DIR/raw/run_N${ppr}_${run_idx}.log"
        taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
            -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
            -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$DURATION" \
            > "$logfile" 2>&1

        qps=$(extract_qps   "$logfile")
        r_avg=$(extract_r_avg "$logfile")
        r_p99=$(extract_r_p99 "$logfile")
        w_avg=$(extract_w_avg "$logfile")
        w_p99=$(extract_w_p99 "$logfile")

        printf "    run %d/%d: QPS=%.0f  r_avg=%s r_p99=%s\n" \
            "$run_idx" "$RUNS" "$qps" "$r_avg" "$r_p99"

        qps_list="$qps_list $qps"
        r_avg_list="$r_avg_list $r_avg"
        r_p99_list="$r_p99_list $r_p99"
        w_avg_list="$w_avg_list $w_avg"
        w_p99_list="$w_p99_list $w_p99"

        echo "$ppr,$SPIN_ROUNDS,$total_budget,$run_idx,$qps,$r_avg,$r_p99,$w_avg,$w_p99" \
            >> "$RESULT_DIR/raw.csv"
    done

    read mean_qps med_qps sd_qps cv_qps <<< "$(compute_stats $qps_list)"
    printf "    STATS: QPS_mean=%.0f  median=%.0f  sd=%.0f  cv=%.2f%%\n" \
        "$mean_qps" "$med_qps" "$sd_qps" "$cv_qps"

    echo "| $ppr | $total_budget | $mean_qps | $med_qps | $sd_qps | $cv_qps | $RUNS |" \
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
