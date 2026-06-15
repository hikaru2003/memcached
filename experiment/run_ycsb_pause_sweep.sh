#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_ycsb_pause_sweep.sh
#
# Description:
#   YCSB VAR ワークロード（Facebook-like: Zipf, 82% SET, 100k keys, 500B）で
#   pause-spinlock ブランチの MEMCACHED_PAUSE_COUNT を sweep し、
#   master baseline と比較する。
#
#   mutilate と異なる点:
#     - キー分布: Zipfian（hotspot 集中）vs mutilate -r 1（単一キー）
#     - 値サイズ: 500B（slabs_lock 競合が顕著）
#     - 82% SET → スラブアロケーター負荷大
#     - Java クライアント（16スレッド）→ 自然な間隔あり
#
# Parameters (env vars):
#   MEMCACHED_BIN   - pause-spinlock バイナリ            (default: ./memcached)
#   MASTER_BIN      - master バイナリ                    (default: ./memcached_master)
#   YCSB_BIN        - YCSB 実行スクリプト               (default: ../ycsb-0.17.0/bin/ycsb.sh)
#   WORKLOAD        - YCSB ワークロード定義              (default: ./experiment/workloads/var_workload.dat)
#   PAUSE_VALUES    - sweep する pause_count 値          (default: "0 10 30 50 70 100")
#   WARMUP_SEC      - warmup 秒数（YCSB run phase）      (default: 60)
#   DURATION        - 計測秒数                           (default: 30)
#   RUNS            - pause 値ごとのラン数               (default: 5)
#   MC_THREADS      - memcached ワーカースレッド数        (default: 32)
#   YCSB_THREADS    - YCSB クライアントスレッド数         (default: 16)
#   PORT            - memcached ポート                   (default: 11222)
#
# Output:
#   experiment/results/ycsb_var_pause_sweep_YYYYMMDD_HHMMSS/
#     summary.md         - pause_count 別 OPS・latency・gain% テーブル
#     raw.csv
#     master_baseline/
#       summary.md
#       run_{n}.log
#     run_P{pause}_{run}.log
#
# Prerequisites:
#   - ./memcached      : experiment/pause-spinlock ブランチのビルド
#   - ./memcached_master: master ブランチのビルド
#   - YCSB 0.17.0 インストール済み

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached}"
MASTER_BIN="${MASTER_BIN:-./memcached_master}"
YCSB_BIN="${YCSB_BIN:-../ycsb-0.17.0/bin/ycsb.sh}"
WORKLOAD="${WORKLOAD:-./experiment/workloads/var_workload.dat}"
PAUSE_VALUES="${PAUSE_VALUES:-0 10 30 50 70 100}"
WARMUP_SEC="${WARMUP_SEC:-60}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-5}"
MC_THREADS="${MC_THREADS:-8}"
YCSB_THREADS="${YCSB_THREADS:-4}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"

RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
_BASE="experiment/results/ycsb_var_pause_sweep_t${MC_THREADS}_yt${YCSB_THREADS}"
RESULT_DIR="$_BASE"
_i=2; while [ -d "$RESULT_DIR" ]; do RESULT_DIR="${_BASE}_run${_i}"; _i=$((_i+1)); done
BASELINE_DIR="$RESULT_DIR/master_baseline"
mkdir -p "$RESULT_DIR" "$BASELINE_DIR"
{
    echo "# Run info"
    echo "- date: ${RUN_DATE}"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- mc_threads: $MC_THREADS / ycsb_threads: $YCSB_THREADS"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- pause_values: $PAUSE_VALUES"
    echo "- workload: $WORKLOAD"
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
    local bin=$1 pause_count=${2:-""} ; cleanup
    if [ -n "$pause_count" ]; then
        MEMCACHED_PAUSE_COUNT=$pause_count taskset -c "$MC_CPUS" "$bin" -p "$PORT" -t "$MC_THREADS" -m 512 -u nobody 2>&1 &
    else
        taskset -c "$MC_CPUS" "$bin" -p "$PORT" -t "$MC_THREADS" -m 512 -u nobody 2>&1 &
    fi
    MC_PID=$!
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  pause_count=${pause_count:-master}  (port $PORT ready)"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

load_ycsb() {
    local logfile=$1
    taskset -c "$WL_CPUS" "$YCSB_BIN" load memcached -s \
        -P "$WORKLOAD" \
        -p "memcached.hosts=127.0.0.1:$PORT" \
        -threads "$YCSB_THREADS" \
        > "$logfile" 2>&1
}

run_ycsb() {
    local logfile=$1 duration=$2
    taskset -c "$WL_CPUS" "$YCSB_BIN" run memcached -s \
        -P "$WORKLOAD" \
        -p "memcached.hosts=127.0.0.1:$PORT" \
        -p "maxexecutiontime=$duration" \
        -threads "$YCSB_THREADS" \
        > "$logfile" 2>&1
}

extract_ops()        { grep "^\[OVERALL\], Throughput"             "$1" | awk -F', ' '{print $3}'; }
extract_read_avg()   { grep "^\[READ\], AverageLatency"            "$1" | awk -F', ' '{print $3}'; }
extract_read_p99()   { grep "^\[READ\], 99thPercentileLatency"     "$1" | awk -F', ' '{print $3}'; }
# [UPDATE] succeeds only after load phase; fall back to [UPDATE-FAILED] is not used here
extract_update_avg() { grep "^\[UPDATE\], AverageLatency"          "$1" | awk -F', ' '{print $3}'; }
extract_update_p99() { grep "^\[UPDATE\], 99thPercentileLatency"   "$1" | awk -F', ' '{print $3}'; }

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

compute_mean() {
    echo "$@" | tr ' ' '\n' | awk 'NF{s+=$1;c++} END{if(c>0) printf "%.2f",s/c; else print "0.00"}'
}

echo "============================================================"
echo " YCSB VAR pause sweep  (get50_set50 equivalent)"
echo "============================================================"
echo " pause-spinlock : $MEMCACHED_BIN"
echo " master         : $MASTER_BIN"
echo " ycsb           : $YCSB_BIN"
echo " workload       : $WORKLOAD"
echo " mc_threads     : $MC_THREADS  ycsb_threads: $YCSB_THREADS"
echo " warmup         : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " PAUSE values   : $PAUSE_VALUES"
echo " results        : $RESULT_DIR"
echo "============================================================"

# ----------------------------------------------------------------
# Phase 1: master baseline
# ----------------------------------------------------------------
echo ""; echo "===== master baseline ====="
start_memcached "$MASTER_BIN" ""
echo "    load phase (inserting ${recordcount:-100000} keys) ..."
load_ycsb "$BASELINE_DIR/load.log"
echo "    warmup ${WARMUP_SEC}s ..."
run_ycsb "$BASELINE_DIR/warmup.log" "$WARMUP_SEC"

ops_list="" r_avg_list="" r_p99_list="" u_avg_list="" u_p99_list=""
for run_idx in $(seq 1 "$RUNS"); do
    logfile="$BASELINE_DIR/run_${run_idx}.log"
    run_ycsb "$logfile" "$DURATION"
    ops=$(extract_ops "$logfile")
    r_avg=$(extract_read_avg   "$logfile")
    r_p99=$(extract_read_p99   "$logfile")
    u_avg=$(extract_update_avg "$logfile")
    u_p99=$(extract_update_p99 "$logfile")
    printf "    run %d/%d: OPS=%.1f  r_avg=%sus  u_avg=%sus\n" \
        "$run_idx" "$RUNS" "$ops" "$r_avg" "$u_avg"
    ops_list="$ops_list $ops"
    r_avg_list="$r_avg_list $r_avg"; r_p99_list="$r_p99_list $r_p99"
    u_avg_list="$u_avg_list $u_avg"; u_p99_list="$u_p99_list $u_p99"
done

read m_ops m_med m_sd m_mn m_mx m_cv <<< "$(compute_stats $ops_list)"
m_r_avg=$(compute_mean $r_avg_list); m_r_p99=$(compute_mean $r_p99_list)
m_u_avg=$(compute_mean $u_avg_list); m_u_p99=$(compute_mean $u_p99_list)

printf "    STATS: mean=%.1f  sd=%.1f  cv=%.2f%%\n" "$m_ops" "$m_sd" "$m_cv"

{
    echo "# master baseline / YCSB VAR / t=${MC_THREADS} / ycsb_threads=${YCSB_THREADS} / n=${RUNS}"
    echo ""
    echo "| label | mean_OPS | median_OPS | stddev_OPS | cv_pct | read_avg_us | read_p99_us | update_avg_us | update_p99_us | n |"
    echo "|---|---|---|---|---|---|---|---|---|---|"
    echo "| master_baseline | $m_ops | $m_med | $m_sd | $m_cv | $m_r_avg | $m_r_p99 | $m_u_avg | $m_u_p99 | $RUNS |"
} > "$BASELINE_DIR/summary.md"
cleanup; sleep 1

# ----------------------------------------------------------------
# Phase 2: pause-spinlock sweep
# ----------------------------------------------------------------
{
    echo "# YCSB VAR pause sweep / t=${MC_THREADS} / ycsb_threads=${YCSB_THREADS} / n=${RUNS}"
    echo "# Workload: Zipf s=1.107, 82% SET, 100k keys, 500B values"
    echo "# master baseline: OPS=${m_ops}  r_avg=${m_r_avg}us  u_avg=${m_u_avg}us"
    echo ""
    echo "| pause_count | mean_OPS | median_OPS | stddev_OPS | cv_pct | read_avg_us | read_p99_us | update_avg_us | update_p99_us | gain_vs_master% | n |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|"
} > "$RESULT_DIR/summary.md"
echo "pause_count,run,OPS,read_avg_us,update_avg_us" > "$RESULT_DIR/raw.csv"

for pause_count in $PAUSE_VALUES; do
    echo ""; echo ">>> PAUSE_COUNT=$pause_count"
    start_memcached "$MEMCACHED_BIN" "$pause_count"
    echo "    load phase ..."
    load_ycsb "$RESULT_DIR/load_P${pause_count}.log"
    echo "    warmup ${WARMUP_SEC}s ..."
    run_ycsb "$RESULT_DIR/warmup_P${pause_count}.log" "$WARMUP_SEC"

    ops_list="" r_avg_list="" r_p99_list="" u_avg_list="" u_p99_list=""
    for run_idx in $(seq 1 "$RUNS"); do
        logfile="$RESULT_DIR/run_P${pause_count}_${run_idx}.log"
        run_ycsb "$logfile" "$DURATION"
        ops=$(extract_ops "$logfile")
        r_avg=$(extract_read_avg   "$logfile")
        r_p99=$(extract_read_p99   "$logfile")
        u_avg=$(extract_update_avg "$logfile")
        u_p99=$(extract_update_p99 "$logfile")
        printf "    run %d/%d: OPS=%.1f  r_avg=%sus  u_avg=%sus\n" \
            "$run_idx" "$RUNS" "$ops" "$r_avg" "$u_avg"
        ops_list="$ops_list $ops"
        r_avg_list="$r_avg_list $r_avg"; r_p99_list="$r_p99_list $r_p99"
        u_avg_list="$u_avg_list $u_avg"; u_p99_list="$u_p99_list $u_p99"
        echo "$pause_count,$run_idx,$ops,$r_avg,$u_avg" >> "$RESULT_DIR/raw.csv"
    done

    read mean_ops median_ops sd_ops mn_ops mx_ops cv_ops <<< "$(compute_stats $ops_list)"
    mean_r_avg=$(compute_mean $r_avg_list); mean_r_p99=$(compute_mean $r_p99_list)
    mean_u_avg=$(compute_mean $u_avg_list); mean_u_p99=$(compute_mean $u_p99_list)

    gain=$(awk "BEGIN { if ($m_ops > 0) printf \"%+.1f\", ($mean_ops - $m_ops) / $m_ops * 100; else print \"N/A\" }")
    printf "    STATS: mean=%.1f  sd=%.1f  cv=%.2f%%  gain=%s%%\n" \
        "$mean_ops" "$sd_ops" "$cv_ops" "$gain"

    echo "| $pause_count | $mean_ops | $median_ops | $sd_ops | $cv_ops | $mean_r_avg | $mean_r_p99 | $mean_u_avg | $mean_u_p99 | ${gain}% | $RUNS |" \
        >> "$RESULT_DIR/summary.md"

    cleanup; sleep 1
done

echo ""
echo "============================================================"
echo " FINAL SUMMARY"
echo "============================================================"
echo "master: OPS=${m_ops}  r_avg=${m_r_avg}us  u_avg=${m_u_avg}us"
echo ""
cat "$RESULT_DIR/summary.md"
echo ""
echo "Results: $RESULT_DIR"
