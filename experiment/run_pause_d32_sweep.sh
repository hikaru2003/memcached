#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_pause_d32_sweep.sh
#
# Description:
#   d=32 / 4conn の設定で master と pause-spinlock を比較する。
#   UPDATE_RATIO_VALUES で GET:SET 比率をスイープし、各比率で PAUSE 効果を計測する。
#
#   各比率ごとに:
#     Phase 1: master baseline 計測
#     Phase 2: pause-spinlock sweep (PAUSE_VALUES をスイープ)
#
# Parameters (env vars):
#   MEMCACHED_BIN        - pause-spinlock バイナリ            (default: ./memcached_pause-spinlock)
#   MASTER_BIN           - master バイナリ                    (default: ./memcached_master)
#   MUTILATE_BIN         - mutilate バイナリ                  (default: ../mutilate/mutilate)
#   MC_THREADS           - memcached ワーカースレッド数        (default: 4)
#   MUT_THREADS          - mutilate クライアントスレッド数     (default: 4)
#   MUT_CONNS            - mutilate コネクション/スレッド      (default: 1) → total=4
#   DEPTH                - mutilate pipeline depth (-d)        (default: 32)
#   PAUSE_VALUES         - PAUSE_COUNT sweep 値               (default: "0 10 20 30 40 50 60 70 80 90 100 200 300 400 500 600 700 800 900 1000")
#   UPDATE_RATIO_VALUES  - GET:SET 比率 sweep 値 (SET割合)     (default: "0.0 0.5 1.0")
#   RECORDS              - key range                           (default: 1)
#   WARMUP_SEC           - warmup 秒数                        (default: 300)
#   DURATION             - 計測秒数                           (default: 60)
#   RUNS                 - 各設定ごとのラン数                  (default: 10)
#   PORT                 - memcached ポート                   (default: 11222)
#   MC_CPUS              - memcached CPU affinity             (default: 0-3)
#   WL_CPUS              - mutilate CPU affinity              (default: 4-7)
#
# Output:
#   experiment/results/pause_d32_mc{MC}_mut{MT}/
#     run_info.md              - 実験日時・パラメータ
#     summary.md               - 比率横断テーブル (master_QPS / best_gain%)
#     get{X}_set{Y}/           - 各比率のサブディレクトリ
#       raw.csv
#       summary.md             - PAUSE値別 QPS・latency・gain% テーブル
#       master_baseline/raw/   - master baseline ログ
#       raw/                   - pause-spinlock ログ
#
# Prerequisites:
#   - ./memcached_pause-spinlock: experiment/pause-spinlock ブランチのビルド
#   - ./memcached_master        : master ブランチのビルド
#   - mutilate binary at ../mutilate/mutilate (or set MUTILATE_BIN)

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached_pause-spinlock}"
MASTER_BIN="${MASTER_BIN:-./memcached_master}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
MC_THREADS="${MC_THREADS:-4}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-1}"
DEPTH="${DEPTH:-32}"
PAUSE_VALUES="${PAUSE_VALUES:-0 10 20 30 40 50 60 70 80 90 100 200 300}"
UPDATE_RATIO_VALUES="${UPDATE_RATIO_VALUES:-0.0 1.0}"
RECORDS="${RECORDS:-1}"
WARMUP_SEC="${WARMUP_SEC:-300}"
DURATION="${DURATION:-60}"
RUNS="${RUNS:-10}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"

TOTAL_CONNS=$(( MUT_THREADS * MUT_CONNS ))
RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
_BASE="experiment/results/pause_d32_mc${MC_THREADS}_mut${MUT_THREADS}"
RESULT_DIR="$_BASE"
_i=2; while [ -d "$RESULT_DIR" ]; do RESULT_DIR="${_BASE}_run${_i}"; _i=$((_i+1)); done
mkdir -p "$RESULT_DIR"

n_ratios=$(echo "$UPDATE_RATIO_VALUES" | wc -w)
n_pause=$(echo "$PAUSE_VALUES" | wc -w)
# 比率ごとに: warmup×1(baseline) + RUNS×duration(baseline) + (pause値ごとに warmup×1 + RUNS×duration)
sec_per_ratio=$(( (WARMUP_SEC + DURATION * RUNS) + n_pause * (WARMUP_SEC + DURATION * RUNS) ))
est_sec=$(( n_ratios * sec_per_ratio ))
est_min=$(( est_sec / 60 ))

{
    echo "# Run info"
    echo "- date: ${RUN_DATE}"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- mc_threads: $MC_THREADS (cpus: $MC_CPUS)"
    echo "- mut_threads: $MUT_THREADS (cpus: $WL_CPUS)"
    echo "- mut_conns: $MUT_CONNS / total_conns: $TOTAL_CONNS"
    echo "- depth: $DEPTH"
    echo "- records: $RECORDS"
    echo "- update_ratio_sweep: $UPDATE_RATIO_VALUES"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- pause_values: $PAUSE_VALUES"
    echo "- master_bin: $MASTER_BIN"
    echo "- spinlock_bin: $MEMCACHED_BIN"
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
    local bin=$1 pause=${2:-""}; cleanup
    if [ -n "$pause" ]; then
        MEMCACHED_PAUSE_COUNT=$pause \
            taskset -c "$MC_CPUS" "$bin" -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
    else
        taskset -c "$MC_CPUS" "$bin" -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
    fi
    MC_PID=$!
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  bin=$(basename "$bin")  pause=${pause:--}  (port $PORT ready)"
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
compute_mean() {
    echo "$@" | tr ' ' '\n' | awk 'NF{s+=$1;c++} END{if(c>0) printf "%.1f", s/c; else printf "0.0"}'
}

echo "============================================================"
echo " pause d32 sweep  (master vs pause-spinlock)"
echo "============================================================"
echo " master_bin  : $MASTER_BIN"
echo " spinlock_bin: $MEMCACHED_BIN"
echo " mc_threads  : $MC_THREADS  cpus: $MC_CPUS"
echo " mut         : -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH  (total_conns=$TOTAL_CONNS)"
echo " records     : $RECORDS"
echo " ratio sweep : $UPDATE_RATIO_VALUES"
echo " warmup      : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " pause values: $PAUSE_VALUES"
echo " conditions  : ${n_ratios} ratios × $(( n_pause + 1 )) labels  (est. ~${est_min} min)"
echo " results     : $RESULT_DIR"
echo "============================================================"

# トップレベル比率横断サマリのヘッダ
{
    echo "# pause_d32 ratio sweep / mc=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -d ${DEPTH} -r ${RECORDS} / n=${RUNS}"
    echo ""
    echo "| ratio | master_QPS | best_pause | best_QPS | best_gain% |"
    echo "|---|---|---|---|---|"
} > "$RESULT_DIR/summary.md"

# ================================================================
# 外ループ: UPDATE_RATIO
# ================================================================
for UPDATE_RATIO in $UPDATE_RATIO_VALUES; do
    get_pct=$(awk "BEGIN { printf \"%d\", (1 - $UPDATE_RATIO) * 100 }")
    set_pct=$(awk "BEGIN { printf \"%d\", $UPDATE_RATIO * 100 }")
    ratio_name="get${get_pct}_set${set_pct}"
    RATIO_DIR="$RESULT_DIR/$ratio_name"
    BASELINE_DIR="$RATIO_DIR/master_baseline"
    mkdir -p "$RATIO_DIR/raw" "$BASELINE_DIR/raw"

    echo ""
    echo "################################################################"
    echo " ratio: $ratio_name  (update_ratio=$UPDATE_RATIO)"
    echo "################################################################"

    # ----------------------------------------------------------------
    # Phase 1: master baseline
    # ----------------------------------------------------------------
    echo ""; echo "===== Phase 1: master baseline ($ratio_name) ====="
    start_memcached "$MASTER_BIN" ""
    echo "    warmup ${WARMUP_SEC}s ..."
    warmup

    echo "label,run,QPS,r_avg_us,r_p99_us,w_avg_us,w_p99_us" > "$RATIO_DIR/raw.csv"
    qps_list="" r_avg_list="" r_p99_list="" w_avg_list="" w_p99_list=""
    for run_idx in $(seq 1 "$RUNS"); do
        logfile="$BASELINE_DIR/raw/run_${run_idx}.log"
        run_mutilate "$logfile" > /dev/null
        qps=$(extract_qps   "$logfile")
        r_avg=$(extract_r_avg "$logfile")
        r_p99=$(extract_r_p99 "$logfile")
        w_avg=$(extract_w_avg "$logfile")
        w_p99=$(extract_w_p99 "$logfile")
        printf "    run %d/%d: QPS=%.0f  r_avg=%sus  r_p99=%sus\n" \
            "$run_idx" "$RUNS" "$qps" "$r_avg" "$r_p99"
        qps_list="$qps_list $qps"
        r_avg_list="$r_avg_list $r_avg"
        r_p99_list="$r_p99_list $r_p99"
        w_avg_list="$w_avg_list $w_avg"
        w_p99_list="$w_p99_list $w_p99"
        echo "master_baseline,$run_idx,$qps,$r_avg,$r_p99,$w_avg,$w_p99" >> "$RATIO_DIR/raw.csv"
    done

    read m_qps m_med m_sd m_cv <<< "$(compute_stats $qps_list)"
    m_r_avg=$(compute_mean $r_avg_list)
    m_r_p99=$(compute_mean $r_p99_list)
    m_w_avg=$(compute_mean $w_avg_list)
    m_w_p99=$(compute_mean $w_p99_list)
    printf "    STATS: mean=%.0f  sd=%.0f  cv=%.2f%%\n" "$m_qps" "$m_sd" "$m_cv"

    cleanup; sleep 1

    # ----------------------------------------------------------------
    # Phase 2: pause-spinlock sweep
    # ----------------------------------------------------------------
    {
        echo "# pause_d32 sweep / ratio=${ratio_name} / mc=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -d ${DEPTH} -r ${RECORDS} -u ${UPDATE_RATIO} / n=${RUNS}"
        echo "# total_conns=${TOTAL_CONNS}"
        echo "# master baseline: QPS=${m_qps}  r_avg=${m_r_avg}us  r_p99=${m_r_p99}us  w_avg=${m_w_avg}us  w_p99=${m_w_p99}us"
        echo ""
        echo "| label | mean_QPS | median_QPS | stddev_QPS | cv_pct | r_avg_us | r_p99_us | w_avg_us | w_p99_us | gain_vs_master% | n |"
        echo "|---|---|---|---|---|---|---|---|---|---|---|"
        echo "| master_baseline | $m_qps | $m_med | $m_sd | $m_cv | $m_r_avg | $m_r_p99 | $m_w_avg | $m_w_p99 | +0.0% | $RUNS |"
    } > "$RATIO_DIR/summary.md"

    echo ""; echo "===== Phase 2: pause-spinlock sweep ($ratio_name) ====="
    best_pause="-" best_qps="0" best_gain="+0.0"
    for pause_count in $PAUSE_VALUES; do
        echo ""; echo ">>> PAUSE_COUNT=$pause_count"
        start_memcached "$MEMCACHED_BIN" "$pause_count"
        echo "    warmup ${WARMUP_SEC}s ..."
        warmup

        qps_list="" r_avg_list="" r_p99_list="" w_avg_list="" w_p99_list=""
        for run_idx in $(seq 1 "$RUNS"); do
            logfile="$RATIO_DIR/raw/run_P${pause_count}_${run_idx}.log"
            run_mutilate "$logfile" > /dev/null
            qps=$(extract_qps   "$logfile")
            r_avg=$(extract_r_avg "$logfile")
            r_p99=$(extract_r_p99 "$logfile")
            w_avg=$(extract_w_avg "$logfile")
            w_p99=$(extract_w_p99 "$logfile")
            printf "    run %d/%d: QPS=%.0f  r_avg=%sus  r_p99=%sus\n" \
                "$run_idx" "$RUNS" "$qps" "$r_avg" "$r_p99"
            qps_list="$qps_list $qps"
            r_avg_list="$r_avg_list $r_avg"
            r_p99_list="$r_p99_list $r_p99"
            w_avg_list="$w_avg_list $w_avg"
            w_p99_list="$w_p99_list $w_p99"
            echo "pause_${pause_count},$run_idx,$qps,$r_avg,$r_p99,$w_avg,$w_p99" >> "$RATIO_DIR/raw.csv"
        done

        read mean_qps med_qps sd_qps cv_qps <<< "$(compute_stats $qps_list)"
        mean_r_avg=$(compute_mean $r_avg_list)
        mean_r_p99=$(compute_mean $r_p99_list)
        mean_w_avg=$(compute_mean $w_avg_list)
        mean_w_p99=$(compute_mean $w_p99_list)
        gain=$(awk "BEGIN { printf \"%+.1f\", ($mean_qps - $m_qps) / $m_qps * 100 }")
        printf "    STATS: mean=%.0f  sd=%.0f  cv=%.2f%%  gain=%s%%\n" \
            "$mean_qps" "$sd_qps" "$cv_qps" "$gain"

        echo "| pause_${pause_count} | $mean_qps | $med_qps | $sd_qps | $cv_qps | $mean_r_avg | $mean_r_p99 | $mean_w_avg | $mean_w_p99 | ${gain}% | $RUNS |" \
            >> "$RATIO_DIR/summary.md"

        # best gain 追跡
        is_best=$(awk "BEGIN { print ($mean_qps > $best_qps) ? 1 : 0 }")
        if [ "$is_best" = "1" ]; then
            best_pause="$pause_count"; best_qps="$mean_qps"; best_gain="$gain"
        fi

        cleanup; sleep 1
    done

    echo "| $ratio_name | $m_qps | $best_pause | $best_qps | ${best_gain}% |" \
        >> "$RESULT_DIR/summary.md"

    echo ""
    echo "  [${ratio_name}] master=${m_qps}  best=pause_${best_pause}(${best_qps})  gain=${best_gain}%"
done

echo ""
echo "============================================================"
echo " FINAL SUMMARY"
echo "============================================================"
cat "$RESULT_DIR/summary.md"
echo ""
echo "Results: $RESULT_DIR"
