#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_saturation_sweep.sh
#
# Description:
#   コネクション数を変化させて memcached の飽和点を探す実験。
#   memcached は cores 0-3 に固定、mutilate は cores 4-7 に固定。
#
#   クローズドループ（mutilate のデフォルト）で接続数を増やすと
#   QPS が頭打ちになる点 = 飽和点。
#   同時に p99 レイテンシの急騰でも飽和を確認する。
#
#   変化させるパラメータ:
#     MUT_CONNS_VALUES: 各コネクション数 (MUT_THREADS=4 固定)
#     → 総コネクション数 = MUT_THREADS × MUT_CONNS
#
# Parameters (env vars):
#   MEMCACHED_BIN     - memcached binary                   (default: ./memcached)
#   MUTILATE_BIN      - mutilate binary                    (default: ../mutilate/mutilate)
#   MC_THREADS        - memcached worker threads           (default: 4)
#   MUT_THREADS       - mutilate client threads (fixed)    (default: 4)
#   MUT_CONNS_VALUES  - sweep する conns/thread 値         (default: "1 2 4 8 16 32 64")
#   UPDATE_RATIO      - GET:SET 比率                       (default: 0.5 = get50_set50)
#   RECORDS           - key range                          (default: 1 = single key)
#   WARMUP_SEC        - warmup 秒数                        (default: 10)
#   DURATION          - 計測秒数                           (default: 30)
#   RUNS              - コネクション値ごとのラン数          (default: 3)
#   PORT              - memcached ポート                   (default: 11222)
#   MC_CPUS           - memcached CPU affinity            (default: 0-3)
#   WL_CPUS           - mutilate CPU affinity             (default: 4-7)
#   PAUSE_COUNT       - MEMCACHED_PAUSE_COUNT             (default: 0)
#   DEPTH             - mutilate pipeline depth (-d)      (default: 8)
#
# Output:
#   experiment/results/saturation_sweep_t{MC}_T{MT}_r{REC}/
#     run_info.md    - 実験日時・パラメータ
#     summary.md     - コネクション数別 QPS・latency テーブル
#     raw.csv
#     run_C{conns}_{run}.log
#
# Prerequisites:
#   - memcached built on experiment/pause-spinlock branch
#   - mutilate binary at ../mutilate/mutilate (or set MUTILATE_BIN)

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
MC_THREADS="${MC_THREADS:-8}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS_VALUES="${MUT_CONNS_VALUES:-1 2 4 8 16 32 64}"
UPDATE_RATIO="${UPDATE_RATIO:-0.5}"
RECORDS="${RECORDS:-1}"
WARMUP_SEC="${WARMUP_SEC:-10}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-3}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"
PAUSE_COUNT="${PAUSE_COUNT:-0}"
DEPTH="${DEPTH:-8}"

RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
_BASE="experiment/results/saturation_sweep_t${MC_THREADS}_T${MUT_THREADS}_r${RECORDS}"
RESULT_DIR="$_BASE"
_i=2; while [ -d "$RESULT_DIR" ]; do RESULT_DIR="${_BASE}_run${_i}"; _i=$((_i+1)); done
mkdir -p "$RESULT_DIR"
{
    echo "# Run info"
    echo "- date: ${RUN_DATE}"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- mc_threads: $MC_THREADS (cpus: $MC_CPUS)"
    echo "- mut_threads: $MUT_THREADS (cpus: $WL_CPUS)"
    echo "- records: $RECORDS / update_ratio: $UPDATE_RATIO"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- pause_count: $PAUSE_COUNT"
    echo "- depth: $DEPTH"
    echo "- conns_sweep: $MUT_CONNS_VALUES"
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
    cleanup
    MEMCACHED_PAUSE_COUNT=$PAUSE_COUNT \
        taskset -c "$MC_CPUS" "$MEMCACHED_BIN" \
        -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
    MC_PID=$!
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  PAUSE_COUNT=$PAUSE_COUNT  (port $PORT ready)"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

run_mutilate() {
    local logfile=$1 mut_conns=$2
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$mut_conns" -d "$DEPTH" -t "$DURATION" \
        2>&1 | tee "$logfile"
}

extract_qps()     { grep -E "^Total QPS" "$1" | awk '{print $4}'; }
extract_avg_us()  { grep -E "^read"      "$1" | awk '{print $2}'; }
extract_p99_us()  { grep -E "^read"      "$1" | awk '{print $8}'; }
extract_w_avg()   { grep -E "^update"    "$1" | awk '{print $2}'; }
extract_w_p99()   { grep -E "^update"    "$1" | awk '{print $8}'; }

compute_mean() {
    echo "$@" | tr ' ' '\n' | awk 'NF{s+=$1;c++} END{if(c>0) printf "%.1f",s/c; else print "0.0"}'
}

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
        printf "%.1f %.1f %.1f %.2f",mean,med,sd,cv
    }'
}

echo "============================================================"
echo " memcached saturation sweep"
echo "============================================================"
echo " binary     : $MEMCACHED_BIN"
echo " mc_threads : $MC_THREADS  cpus: $MC_CPUS"
echo " mut_threads: $MUT_THREADS  cpus: $WL_CPUS"
echo " records    : $RECORDS  update_ratio: $UPDATE_RATIO"
echo " pause_count: $PAUSE_COUNT"
echo " depth      : $DEPTH"
echo " warmup     : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " conns sweep: $MUT_CONNS_VALUES  (total = MUT_THREADS × MUT_CONNS)"
echo " results    : $RESULT_DIR"
echo "============================================================"

{
    echo "# saturation sweep / t=${MC_THREADS} / mutilate -T ${MUT_THREADS} -d ${DEPTH} -r ${RECORDS} -u ${UPDATE_RATIO} / n=${RUNS}"
    echo "# PAUSE_COUNT=${PAUSE_COUNT}"
    echo ""
    echo "| total_conns | mut_conns | mean_QPS | median_QPS | stddev_QPS | cv_pct | r_avg_us | r_p99_us | w_avg_us | w_p99_us | n |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|"
} > "$RESULT_DIR/summary.md"
echo "total_conns,mut_conns,run,QPS,r_avg_us,r_p99_us,w_avg_us,w_p99_us" > "$RESULT_DIR/raw.csv"

start_memcached

for mut_conns in $MUT_CONNS_VALUES; do
    total_conns=$(( MUT_THREADS * mut_conns ))
    echo ""
    echo ">>> total_conns=$total_conns  (MUT_THREADS=$MUT_THREADS × MUT_CONNS=$mut_conns)"

    # warmup
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$mut_conns" -d "$DEPTH" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true

    qps_list="" r_avg_list="" r_p99_list="" w_avg_list="" w_p99_list=""

    for run_idx in $(seq 1 "$RUNS"); do
        logfile="$RESULT_DIR/run_C${total_conns}_${run_idx}.log"
        run_mutilate "$logfile" "$mut_conns" > /dev/null
        qps=$(extract_qps    "$logfile")
        r_avg=$(extract_avg_us "$logfile")
        r_p99=$(extract_p99_us "$logfile")
        w_avg=$(extract_w_avg  "$logfile")
        w_p99=$(extract_w_p99  "$logfile")
        printf "    run %d/%d: QPS=%.0f  r_avg=%sus  r_p99=%sus\n" \
            "$run_idx" "$RUNS" "$qps" "$r_avg" "$r_p99"
        qps_list="$qps_list $qps"
        r_avg_list="$r_avg_list $r_avg"
        r_p99_list="$r_p99_list $r_p99"
        w_avg_list="$w_avg_list $w_avg"
        w_p99_list="$w_p99_list $w_p99"
        echo "$total_conns,$mut_conns,$run_idx,$qps,$r_avg,$r_p99,$w_avg,$w_p99" >> "$RESULT_DIR/raw.csv"
    done

    read mean_qps median_qps sd_qps cv_qps <<< "$(compute_stats $qps_list)"
    mean_r_avg=$(compute_mean $r_avg_list)
    mean_r_p99=$(compute_mean $r_p99_list)
    mean_w_avg=$(compute_mean $w_avg_list)
    mean_w_p99=$(compute_mean $w_p99_list)

    printf "    STATS: mean=%.0f  sd=%.0f  cv=%.2f%%\n" "$mean_qps" "$sd_qps" "$cv_qps"
    echo "| $total_conns | $mut_conns | $mean_qps | $median_qps | $sd_qps | $cv_qps | $mean_r_avg | $mean_r_p99 | $mean_w_avg | $mean_w_p99 | $RUNS |" \
        >> "$RESULT_DIR/summary.md"
done

cleanup

echo ""
echo "============================================================"
echo " SUMMARY"
echo "============================================================"
cat "$RESULT_DIR/summary.md"
echo ""
echo "Results: $RESULT_DIR"
