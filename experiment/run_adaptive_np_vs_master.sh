#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_adaptive_np_vs_master.sh
#
# Description:
#   PTHREAD_MUTEX_ADAPTIVE_NP (both item_locks + slabs_lock) vs master を
#   GET:SET ratio sweep で比較する。
#   両バイナリを同じ条件 (-r 1, 固定スレッド数) で計測し、gain% を算出する。
#
# Parameters (env vars):
#   ADAPTIVE_BIN         - adaptive-np バイナリ         (default: ./memcached_adaptive_np)
#   MASTER_BIN           - master バイナリ               (default: ./memcached_master)
#   MUTILATE_BIN         - mutilate バイナリ             (default: ../mutilate/mutilate)
#   WARMUP_SEC           - warmup 秒数                   (default: 60)
#   DURATION             - 計測秒数                      (default: 30)
#   RUNS                 - ratio ごとのラン数             (default: 5)
#   MC_THREADS           - memcached ワーカースレッド数   (default: 32)
#   MUT_THREADS          - mutilate クライアントスレッド  (default: 4)
#   MUT_CONNS            - mutilate コネクション/スレッド (default: 4)
#   PORT                 - memcached ポート              (default: 11222)
#   UPDATE_RATIO_VALUES  - スイープ対象の update_ratio   (default: "0.0 0.1 0.3 0.5 0.7 0.9 1.0")
#
# Output:
#   experiment/results/adaptive_np_vs_master_YYYYMMDD_HHMMSS/
#     summary.md              - 全 ratio の gain% 比較テーブル
#     adaptive_np/
#       summary.md            - adaptive-np 側の ratio 別 QPS 統計
#       raw.csv
#       run_{ratio}_{run}.log
#     master/
#       summary.md            - master 側の ratio 別 QPS 統計
#       raw.csv
#       run_{ratio}_{run}.log
#
# Prerequisites:
#   - memcached_adaptive_np : experiment/adaptive-np-both-locks ブランチのビルド
#   - memcached_master      : master ブランチのビルド
#   - mutilate binary

set -uo pipefail

ADAPTIVE_BIN="${ADAPTIVE_BIN:-./memcached_adaptive_np}"
MASTER_BIN="${MASTER_BIN:-./memcached_master}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
WARMUP_SEC="${WARMUP_SEC:-60}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-5}"
MC_THREADS="${MC_THREADS:-8}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-4}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"
UPDATE_RATIO_VALUES="${UPDATE_RATIO_VALUES:-0.0 0.1 0.3 0.5 0.7 0.9 1.0}"
RECORDS=1

RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
_RATIOS=$(echo "$UPDATE_RATIO_VALUES" | wc -w | tr -d ' ')
_BASE="experiment/results/adaptive_np_vs_master_mc${MC_THREADS}_mut${MUT_THREADS}c${MUT_CONNS}_r${RECORDS}_${_RATIOS}ratios"
RESULT_DIR="$_BASE"
_i=2; while [ -d "$RESULT_DIR" ]; do RESULT_DIR="${_BASE}_run${_i}"; _i=$((_i+1)); done
ADAPTIVE_DIR="$RESULT_DIR/adaptive_np"
MASTER_DIR="$RESULT_DIR/master"
mkdir -p "$ADAPTIVE_DIR/raw" "$MASTER_DIR/raw"
{
    echo "# Run info"
    echo "- date: ${RUN_DATE}"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- mc_threads: $MC_THREADS / mut_threads: $MUT_THREADS / mut_conns: $MUT_CONNS"
    echo "- records: $RECORDS / warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- update_ratio_values: $UPDATE_RATIO_VALUES"
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
    local bin=$1 label=$2; cleanup
    taskset -c "$MC_CPUS" "$bin" -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
    MC_PID=$!
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  binary=$label  (port $PORT ready)"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

run_warmup() {
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$1" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -t "$WARMUP_SEC" > /dev/null 2>&1 || true
}

run_measure() {
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$2" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -t "$DURATION" 2>&1 | tee "$1"
}

extract_qps()       { grep -E "^Total QPS" "$1" | awk '{print $4}'; }
extract_avg_us()    { grep -E "^read"   "$1" | awk '{print $2}'; }
extract_p99_us()    { grep -E "^read"   "$1" | awk '{print $8}'; }
extract_w_avg_us()  { grep -E "^update" "$1" | awk '{print $2}'; }
extract_w_p99_us()  { grep -E "^update" "$1" | awk '{print $8}'; }

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
    echo "$@" | tr ' ' '\n' | awk 'NF{s+=$1;c++} END{if(c>0) printf "%.1f",s/c; else print "0.0"}'
}

# header for sub-summaries
make_sub_summary_header() {
    local outdir=$1 label=$2
    {
        echo "# ${label} / t=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -r ${RECORDS} / n=${RUNS}"
        echo ""
        echo "| ratio | mean_QPS | median_QPS | stddev_QPS | cv_pct | read_avg_us | read_p99_us | write_avg_us | write_p99_us | n |"
        echo "|---|---|---|---|---|---|---|---|---|---|"
    } > "$outdir/summary.md"
    echo "ratio,run,QPS" > "$outdir/raw.csv"
}

# measure one binary for all ratios
measure_binary() {
    local bin=$1 label=$2 outdir=$3

    make_sub_summary_header "$outdir" "$label"

    for update_ratio in $UPDATE_RATIO_VALUES; do
        set_pct=$(awk "BEGIN { printf \"%d\", $update_ratio * 100 }")
        get_pct=$((100 - set_pct))
        ratio_name="get${get_pct}_set${set_pct}"

        echo ""
        echo "  >>> $label  $ratio_name  (update_ratio=$update_ratio)"
        start_memcached "$bin" "$label"
        echo "      warmup ${WARMUP_SEC}s ..."
        run_warmup "$update_ratio"

        qps_list="" r_avg_list="" r_p99_list="" w_avg_list="" w_p99_list=""

        for run_idx in $(seq 1 "$RUNS"); do
            logfile="$outdir/raw/run_${ratio_name}_${run_idx}.log"
            run_measure "$logfile" "$update_ratio" > /dev/null
            qps=$(extract_qps "$logfile")
            r_avg=$(extract_avg_us   "$logfile")
            r_p99=$(extract_p99_us   "$logfile")
            w_avg=$(extract_w_avg_us "$logfile")
            w_p99=$(extract_w_p99_us "$logfile")
            printf "      run %d/%d: QPS=%.1f  r_avg=%sus  w_avg=%sus\n" \
                "$run_idx" "$RUNS" "$qps" "$r_avg" "$w_avg"
            qps_list="$qps_list $qps"
            r_avg_list="$r_avg_list $r_avg"
            r_p99_list="$r_p99_list $r_p99"
            w_avg_list="$w_avg_list $w_avg"
            w_p99_list="$w_p99_list $w_p99"
            echo "$ratio_name,$run_idx,$qps" >> "$outdir/raw.csv"
        done

        read mean_qps median_qps stddev_qps min_qps max_qps cv_pct \
            <<< "$(compute_stats $qps_list)"
        mean_r_avg=$(compute_mean $r_avg_list)
        mean_r_p99=$(compute_mean $r_p99_list)
        mean_w_avg=$(compute_mean $w_avg_list)
        mean_w_p99=$(compute_mean $w_p99_list)

        printf "      STATS: mean=%.1f  sd=%.1f  cv=%.2f%%\n" \
            "$mean_qps" "$stddev_qps" "$cv_pct"

        echo "| $ratio_name | $mean_qps | $median_qps | $stddev_qps | $cv_pct | $mean_r_avg | $mean_r_p99 | $mean_w_avg | $mean_w_p99 | $RUNS |" \
            >> "$outdir/summary.md"

        cleanup; sleep 1
    done
}

echo "============================================================"
echo " ADAPTIVE_NP vs master  /  GET:SET ratio sweep  / -r 1"
echo "============================================================"
echo " adaptive-np : $ADAPTIVE_BIN"
echo " master      : $MASTER_BIN"
echo " mc_threads  : $MC_THREADS  ($(nproc) cores)"
echo " warmup      : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " results     : $RESULT_DIR"
echo "============================================================"

echo ""; echo "===== Phase 1: ADAPTIVE_NP ====="
measure_binary "$ADAPTIVE_BIN" "adaptive-np-both-locks" "$ADAPTIVE_DIR"

echo ""; echo "===== Phase 2: master ====="
measure_binary "$MASTER_BIN" "master" "$MASTER_DIR"

# ---- top-level summary: gain% adaptive-np vs master ----
{
    echo "# ADAPTIVE_NP vs master / GET:SET ratio sweep"
    echo "# t=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -r ${RECORDS} / n=${RUNS}"
    echo ""
    echo "| ratio | master_QPS | adaptive_np_QPS | gain% |"
    echo "|---|---|---|---|"

    for update_ratio in $UPDATE_RATIO_VALUES; do
        set_pct=$(awk "BEGIN { printf \"%d\", $update_ratio * 100 }")
        get_pct=$((100 - set_pct))
        ratio_name="get${get_pct}_set${set_pct}"

        m_qps=$(grep "^| $ratio_name " "$MASTER_DIR/summary.md"   | awk -F'|' '{gsub(/ /,"",$3); print $3}')
        a_qps=$(grep "^| $ratio_name " "$ADAPTIVE_DIR/summary.md" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
        gain=$(awk "BEGIN {
            if (\"$m_qps\" != \"\" && $m_qps > 0)
                printf \"%+.1f\", ($a_qps - $m_qps) / $m_qps * 100
            else print \"N/A\"
        }")
        echo "| $ratio_name | $m_qps | $a_qps | ${gain}% |"
    done
} > "$RESULT_DIR/summary.md"

echo ""
echo "============================================================"
echo " RESULT SUMMARY"
echo "============================================================"
cat "$RESULT_DIR/summary.md"
echo ""
echo "adaptive-np  : $ADAPTIVE_DIR/summary.md"
echo "master       : $MASTER_DIR/summary.md"
echo "comparison   : $RESULT_DIR/summary.md"
