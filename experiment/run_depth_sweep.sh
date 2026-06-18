#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_depth_sweep.sh
#
# Description:
#   memcached_master を使い、サーバスレッド数 × mutilateスレッド数 × depth を
#   スイープして飽和 QPS を計測する。
#
#   MC_THREADS_VALUES の各値ごとに memcached を再起動し、
#   MUT_THREADS_VALUES × DEPTH_VALUES の 2D グリッドを計測する。
#   MUT_CONNS（コネクション/スレッド）は固定値 1。
#
#   CPU affinity はスレッド数ごとに個別指定可能。
#   デフォルト:
#     MC_THREADS=4 → MC_CPUS=0-3 / WL_CPUS=4-7  (1 thread/core、隔離)
#     MC_THREADS=8 → MC_CPUS=0-3 / WL_CPUS=4-7  (2 threads/core、オーバーサブスク)
#   非オーバーサブスク比較:
#     MC_CPUS_8=0-7 に変更すると 8 コア割り当て（WL_CPUS=4-7 と一部共有）
#
# Parameters (env vars):
#   MEMCACHED_BIN        - 計測対象バイナリ                    (default: ./memcached_master)
#   MUTILATE_BIN         - mutilate バイナリ                    (default: ../mutilate/mutilate)
#   MC_THREADS_VALUES    - サーバスレッド数 sweep 値            (default: "4 8")
#   MUT_THREADS_VALUES   - mutilate クライアントスレッド数 sweep (default: "4 8")
#   MUT_CONNS            - mutilate コネクション/スレッド        (default: 1)
#   DEPTH_VALUES         - pipeline depth sweep 値              (default: "1 2 4 6 8 12 16 24 32 48 64 96 128")
#   UPDATE_RATIO         - GET:SET 比率                         (default: 0.5)
#   RECORDS              - key range                            (default: 1)
#   WARMUP_SEC           - 各条件の warmup 秒数                 (default: 30)
#   DURATION             - 計測秒数                             (default: 60)
#   RUNS                 - 各条件ごとのラン数                   (default: 5)
#   PORT                 - memcached ポート                     (default: 11222)
#   MC_CPUS_4            - MC_THREADS=4 時の CPU affinity       (default: 0-3)
#   MC_CPUS_8            - MC_THREADS=8 時の CPU affinity       (default: 0-3, オーバーサブスク)
#   WL_CPUS              - mutilate CPU affinity                (default: 4-7)
#
# Output:
#   experiment/results/saturation_sweep_r{RECORDS}/
#     run_info.md        - 実験日時・パラメータ
#     summary.md         - MC_THREADS × MUT_THREADS × depth 全結果テーブル
#     raw.csv            - per-run 生データ
#     mc{mc_t}_mut{mut_t}/run_d{depth}_{run}.log
#
# Prerequisites:
#   - ./memcached_master: master ブランチのビルド
#   - mutilate binary at ../mutilate/mutilate (or set MUTILATE_BIN)

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached_master}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
MC_THREADS_VALUES="${MC_THREADS_VALUES:-4 8}"
MUT_THREADS_VALUES="${MUT_THREADS_VALUES:-4 8}"
MUT_CONNS="${MUT_CONNS:-1}"
DEPTH_VALUES="${DEPTH_VALUES:-1 2 4 6 8 12 16 24 32 48 64 96 128}"
UPDATE_RATIO="${UPDATE_RATIO:-0.5}"
RECORDS="${RECORDS:-1}"
WARMUP_SEC="${WARMUP_SEC:-30}"
DURATION="${DURATION:-60}"
RUNS="${RUNS:-5}"
PORT="${PORT:-11222}"
MC_CPUS_4="${MC_CPUS_4:-0-3}"
MC_CPUS_8="${MC_CPUS_8:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"

RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
_MC=$(echo "$MC_THREADS_VALUES" | tr ' ' '-')
_MUT=$(echo "$MUT_THREADS_VALUES" | tr ' ' '-')
_BASE="experiment/results/saturation_mc${_MC}_mut${_MUT}_r${RECORDS}"
RESULT_DIR="$_BASE"
_i=2; while [ -d "$RESULT_DIR" ]; do RESULT_DIR="${_BASE}_run${_i}"; _i=$((_i+1)); done
mkdir -p "$RESULT_DIR"

{
    echo "# Run info"
    echo "- date: ${RUN_DATE}"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- binary: $MEMCACHED_BIN"
    echo "- mc_threads_sweep: $MC_THREADS_VALUES"
    echo "- mc_cpus_4: $MC_CPUS_4 / mc_cpus_8: $MC_CPUS_8"
    echo "- mut_threads_sweep: $MUT_THREADS_VALUES (cpus: $WL_CPUS)"
    echo "- mut_conns: $MUT_CONNS"
    echo "- depth_sweep: $DEPTH_VALUES"
    echo "- records: $RECORDS / update_ratio: $UPDATE_RATIO"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
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
    local mc_threads=$1 mc_cpus=$2
    cleanup
    taskset -c "$mc_cpus" "$MEMCACHED_BIN" \
        -p "$PORT" -t "$mc_threads" -m 256 -u nobody 2>&1 &
    MC_PID=$!
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  threads=$mc_threads  cpus=$mc_cpus  (port $PORT ready)"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

run_mutilate() {
    local logfile=$1 mut_threads=$2 depth=$3
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$mut_threads" -c "$MUT_CONNS" -d "$depth" -t "$DURATION" \
        2>&1 | tee "$logfile"
}

warmup() {
    local mut_threads=$1 depth=$2
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$mut_threads" -c "$MUT_CONNS" -d "$depth" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true
}

extract_qps()   { grep -E "^Total QPS" "$1" | awk '{print $4}'; }
extract_r_avg() { grep -E "^read"   "$1" | awk '{print $2}'; }
extract_r_p99() { grep -E "^read"   "$1" | awk '{print $9}'; }
extract_w_avg() { grep -E "^update" "$1" | awk '{print $2}'; }
extract_w_p99() { grep -E "^update" "$1" | awk '{print $9}'; }

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

compute_mean() {
    echo "$@" | tr ' ' '\n' | awk 'NF{s+=$1;c++} END{if(c>0) printf "%.1f", s/c; else printf "0.0"}'
}

# 条件数と推定時間を計算して表示
n_mc=$(echo "$MC_THREADS_VALUES" | wc -w)
n_mut=$(echo "$MUT_THREADS_VALUES" | wc -w)
n_depth=$(echo "$DEPTH_VALUES" | wc -w)
n_cond=$(( n_mc * n_mut * n_depth ))
est_sec=$(( n_cond * (WARMUP_SEC + DURATION * RUNS) ))
est_min=$(( est_sec / 60 ))

echo "============================================================"
echo " saturation sweep  ($(basename "$MEMCACHED_BIN"))"
echo "============================================================"
echo " mc_threads  : $MC_THREADS_VALUES"
echo "   cpus[4]   : $MC_CPUS_4"
echo "   cpus[8]   : $MC_CPUS_8"
echo " mut_threads : $MUT_THREADS_VALUES  cpus: $WL_CPUS"
echo " mut_conns   : $MUT_CONNS  (total_conns = mut_threads × $MUT_CONNS)"
echo " depth values: $DEPTH_VALUES"
echo " records     : $RECORDS  update_ratio: $UPDATE_RATIO"
echo " warmup      : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " conditions  : $n_cond  (est. ~${est_min} min)"
echo " results     : $RESULT_DIR"
echo "============================================================"

# CSV ヘッダ
echo "mc_threads,mc_cpus,mut_threads,mut_conns,total_conns,depth,in_flight,run,QPS,r_avg_us,r_p99_us,w_avg_us,w_p99_us" \
    > "$RESULT_DIR/raw.csv"

# summary.md ヘッダ
{
    echo "# saturation sweep / $(basename "$MEMCACHED_BIN") / mut_conns=${MUT_CONNS} -r ${RECORDS} -u ${UPDATE_RATIO} / n=${RUNS}"
    echo ""
    echo "| mc_threads | mc_cpus | mut_threads | total_conns | depth | in_flight | mean_QPS | median_QPS | stddev_QPS | cv_pct | r_avg_us | r_p99_us | w_avg_us | w_p99_us | n |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
} > "$RESULT_DIR/summary.md"

# ----------------------------------------------------------------
# 外ループ: MC_THREADS（memcached 再起動）
# ----------------------------------------------------------------
for mc_threads in $MC_THREADS_VALUES; do
    case "$mc_threads" in
        4) mc_cpus="$MC_CPUS_4" ;;
        8) mc_cpus="$MC_CPUS_8" ;;
        *) mc_cpus="$MC_CPUS_4" ;;
    esac

    echo ""
    echo "=============================="
    echo " MC_THREADS=$mc_threads  cpus=$mc_cpus"
    echo "=============================="
    start_memcached "$mc_threads" "$mc_cpus"

    # ----------------------------------------------------------------
    # 内ループ: MUT_THREADS × depth
    # ----------------------------------------------------------------
    for mut_threads in $MUT_THREADS_VALUES; do
        total_conns=$(( mut_threads * MUT_CONNS ))
        log_dir="$RESULT_DIR/mc${mc_threads}_mut${mut_threads}"
        mkdir -p "$log_dir/raw"

        echo ""
        echo "  ----- MUT_THREADS=$mut_threads  total_conns=$total_conns -----"

        for depth in $DEPTH_VALUES; do
            in_flight=$(( total_conns * depth ))

            echo ""
            echo "    >>> mc=${mc_threads}  mut=${mut_threads}  depth=${depth}  in_flight=${in_flight}"
            echo "        warmup ${WARMUP_SEC}s ..."
            warmup "$mut_threads" "$depth"

            qps_list="" r_avg_list="" r_p99_list="" w_avg_list="" w_p99_list=""
            for run_idx in $(seq 1 "$RUNS"); do
                logfile="$log_dir/raw/run_d${depth}_${run_idx}.log"
                run_mutilate "$logfile" "$mut_threads" "$depth" > /dev/null
                qps=$(extract_qps   "$logfile")
                r_avg=$(extract_r_avg "$logfile")
                r_p99=$(extract_r_p99 "$logfile")
                w_avg=$(extract_w_avg "$logfile")
                w_p99=$(extract_w_p99 "$logfile")
                printf "        run %d/%d: QPS=%.0f  r_avg=%sus  r_p99=%sus\n" \
                    "$run_idx" "$RUNS" "$qps" "$r_avg" "$r_p99"
                qps_list="$qps_list $qps"
                r_avg_list="$r_avg_list $r_avg"
                r_p99_list="$r_p99_list $r_p99"
                w_avg_list="$w_avg_list $w_avg"
                w_p99_list="$w_p99_list $w_p99"
                echo "$mc_threads,$mc_cpus,$mut_threads,$MUT_CONNS,$total_conns,$depth,$in_flight,$run_idx,$qps,$r_avg,$r_p99,$w_avg,$w_p99" \
                    >> "$RESULT_DIR/raw.csv"
            done

            read mean_qps med_qps sd_qps cv_qps <<< "$(compute_stats $qps_list)"
            mean_r_avg=$(compute_mean $r_avg_list)
            mean_r_p99=$(compute_mean $r_p99_list)
            mean_w_avg=$(compute_mean $w_avg_list)
            mean_w_p99=$(compute_mean $w_p99_list)
            printf "        STATS: mean=%.0f  sd=%.0f  cv=%.2f%%\n" \
                "$mean_qps" "$sd_qps" "$cv_qps"

            echo "| $mc_threads | $mc_cpus | $mut_threads | $total_conns | $depth | $in_flight | $mean_qps | $med_qps | $sd_qps | $cv_qps | $mean_r_avg | $mean_r_p99 | $mean_w_avg | $mean_w_p99 | $RUNS |" \
                >> "$RESULT_DIR/summary.md"
        done
    done

    cleanup; sleep 1
done

echo ""
echo "============================================================"
echo " FINAL SUMMARY"
echo "============================================================"
cat "$RESULT_DIR/summary.md"
echo ""
echo "Results: $RESULT_DIR"
