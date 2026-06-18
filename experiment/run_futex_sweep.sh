#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_futex_sweep.sh
#
# Description:
#   pause-spinlock の PAUSE_COUNT を sweep しながら spinlock futex fallback 数を計測する。
#   最初に master バイナリ (memcached_debug_futex_master) でベースライン計測を行い、
#   その後 PAUSE_COUNT sweep を実行する。
#
#   SIGUSR2 を送信すると、各ワーカースレッドのローカルカウンタを集計してリセットし
#   stderr に "SPINLOCK_FUTEX_COUNT: <N>" を出力する。
#
# Parameters (env vars):
#   MEMCACHED_BIN        - pause-spinlock debug バイナリ       (default: ./memcached_debug_futex)
#   MEMCACHED_MASTER_BIN - master debug バイナリ               (default: ./memcached_debug_futex_master)
#   MUTILATE_BIN         - mutilate バイナリ                   (default: ../mutilate/mutilate)
#   MC_THREADS           - memcached ワーカースレッド数         (default: 4)
#   MUT_THREADS          - mutilate クライアントスレッド数      (default: 4)
#   MUT_CONNS            - mutilate コネクション/スレッド       (default: 1)
#   DEPTH                - mutilate pipeline depth (-d)         (default: 32)
#   PAUSE_VALUES         - PAUSE_COUNT sweep 値                (default: "0 10 20 30 40 50 60 70 80 90 100 200 300")
#   UPDATE_RATIO         - GET:SET 比率 (SET 割合)              (default: 0.5)
#   RECORDS              - key range                            (default: 1)
#   WARMUP_SEC           - warmup 秒数                         (default: 60)
#   DURATION             - 計測秒数                            (default: 30)
#   RUNS                 - 各 PAUSE 値のラン数                  (default: 3)
#   PORT                 - memcached ポート                    (default: 11222)
#   MC_CPUS              - memcached CPU affinity              (default: 0-3)
#   WL_CPUS              - mutilate CPU affinity               (default: 4-7)
#
# Output:
#   experiment/results/debug_futex_sweep_mc{MC}_mut{MUT}/
#     run_info.md       - 実験日時・パラメータ
#     summary.md        - PAUSE値別 futex_per_op / QPS テーブル（master baseline 含む）
#     raw.csv           - per-run 生データ
#     raw/              - mutilate ログ・memcached stderr
#
# Prerequisites:
#   - ./memcached_debug_futex: debug/futex-count ブランチのビルド
#   - ./memcached_debug_futex_master: debug/futex-count-master ブランチのビルド
#   - mutilate binary at ../mutilate/mutilate (or set MUTILATE_BIN)

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached_debug_futex}"
MEMCACHED_MASTER_BIN="${MEMCACHED_MASTER_BIN:-./memcached_debug_futex_master}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
MC_THREADS="${MC_THREADS:-4}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-1}"
DEPTH="${DEPTH:-32}"
PAUSE_VALUES="${PAUSE_VALUES:-0 10 20 30 40 50 60 70 80 90 100 200 300}"
UPDATE_RATIO="${UPDATE_RATIO:-0.5}"
RECORDS="${RECORDS:-1}"
WARMUP_SEC="${WARMUP_SEC:-60}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-3}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"

TOTAL_CONNS=$(( MUT_THREADS * MUT_CONNS ))
RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
_BASE="experiment/results/debug_futex_sweep_mc${MC_THREADS}_mut${MUT_THREADS}"
RESULT_DIR="$_BASE"
_i=2; while [ -d "$RESULT_DIR" ]; do RESULT_DIR="${_BASE}_run${_i}"; _i=$((_i+1)); done
mkdir -p "$RESULT_DIR/raw"

n_pause=$(echo "$PAUSE_VALUES" | wc -w)
est_sec=$(( (n_pause + 1) * (WARMUP_SEC + DURATION * RUNS) ))
est_min=$(( est_sec / 60 ))

{
    echo "# Run info (futex sweep)"
    echo "- date: ${RUN_DATE}"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- spinlock_bin: $MEMCACHED_BIN"
    echo "- master_bin: $MEMCACHED_MASTER_BIN"
    echo "- mc_threads: $MC_THREADS (cpus: $MC_CPUS)"
    echo "- mut: -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH (total_conns=$TOTAL_CONNS)"
    echo "- update_ratio: $UPDATE_RATIO / records: $RECORDS"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- pause_values: $PAUSE_VALUES"
    echo "- est_time: ~${est_min} min"
} > "$RESULT_DIR/run_info.md"

MC_PID=""
MC_LOG=""
cleanup() {
    if [ -n "$MC_PID" ] && kill -0 "$MC_PID" 2>/dev/null; then
        kill "$MC_PID" 2>/dev/null; wait "$MC_PID" 2>/dev/null
    fi
    MC_PID=""
}
trap cleanup EXIT

start_memcached() {
    local bin=$1 pause=$2 log=$3
    cleanup
    MEMCACHED_PAUSE_COUNT=$pause \
        taskset -c "$MC_CPUS" "$bin" \
        -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>"$log" &
    MC_PID=$!
    MC_LOG="$log"
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  bin=$(basename $bin)  PAUSE_COUNT=$pause  log=$log"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

warmup() {
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true
}

reset_futex_counter() {
    kill -USR2 "$MC_PID" 2>/dev/null || true
    sleep 0.2
}

read_futex_count() {
    kill -USR2 "$MC_PID" 2>/dev/null || true
    sleep 0.2
    grep "SPINLOCK_FUTEX_COUNT:" "$MC_LOG" | tail -1 | awk '{print $2}'
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
    echo "$@" | tr ' ' '\n' | awk 'NF{s+=$1;c++} END{if(c>0) printf "%.3f", s/c; else printf "0.000"}'
}

echo "============================================================"
echo " futex sweep  (SIGUSR2 counter, master baseline included)"
echo "============================================================"
echo " spinlock_bin: $MEMCACHED_BIN"
echo " master_bin  : $MEMCACHED_MASTER_BIN"
echo " mc_threads  : $MC_THREADS  cpus: $MC_CPUS"
echo " mut         : -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH  (total_conns=$TOTAL_CONNS)"
echo " update_ratio: $UPDATE_RATIO / records: $RECORDS"
echo " warmup      : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " pause values: $PAUSE_VALUES"
echo " results     : $RESULT_DIR"
echo "============================================================"

echo "pause_count,run,QPS,futex_count,futex_per_sec,futex_per_op,r_avg_us,r_p99_us,w_avg_us,w_p99_us" \
    > "$RESULT_DIR/raw.csv"

{
    echo "# futex sweep / mc=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -d ${DEPTH} -r ${RECORDS} -u ${UPDATE_RATIO} / n=${RUNS}"
    echo ""
    echo "futex_per_op = futex_count / (QPS × DURATION)"
    echo "master = pthread_mutex のみ（スピンなし）の item_lock 競合率"
    echo ""
    echo "| label | mean_QPS | mean_futex_per_sec | mean_futex_per_op | cv_qps% | n |"
    echo "|---|---|---|---|---|---|"
} > "$RESULT_DIR/summary.md"

run_one_pause() {
    local label=$1 bin=$2 pause=$3
    echo ""
    echo "=============================="
    echo " $label"
    echo "=============================="
    local mc_log="$RESULT_DIR/raw/mc_${label}.log"
    start_memcached "$bin" "$pause" "$mc_log"

    echo "    warmup ${WARMUP_SEC}s ..."
    warmup
    echo "    resetting futex counter ..."
    reset_futex_counter

    local qps_list="" futex_per_sec_list="" futex_per_op_list=""
    local r_avg_list="" r_p99_list="" w_avg_list="" w_p99_list=""

    for run_idx in $(seq 1 "$RUNS"); do
        local logfile="$RESULT_DIR/raw/run_${label}_${run_idx}.log"
        taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
            -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
            -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$DURATION" \
            > "$logfile" 2>&1

        local futex_count
        futex_count=$(read_futex_count)
        futex_count="${futex_count:-0}"

        local qps r_avg r_p99 w_avg w_p99
        qps=$(extract_qps   "$logfile")
        r_avg=$(extract_r_avg "$logfile")
        r_p99=$(extract_r_p99 "$logfile")
        w_avg=$(extract_w_avg "$logfile")
        w_p99=$(extract_w_p99 "$logfile")

        local futex_per_sec futex_per_op
        futex_per_sec=$(awk "BEGIN { printf \"%.1f\", $futex_count / $DURATION }")
        futex_per_op=$(awk "BEGIN {
            total_ops = $qps * $DURATION
            if (total_ops > 0) printf \"%.6f\", $futex_count / total_ops
            else printf \"0.000000\"
        }")

        printf "    run %d/%d: QPS=%.0f  futex=%s  futex/op=%s\n" \
            "$run_idx" "$RUNS" "$qps" "$futex_count" "$futex_per_op"

        qps_list="$qps_list $qps"
        futex_per_sec_list="$futex_per_sec_list $futex_per_sec"
        futex_per_op_list="$futex_per_op_list $futex_per_op"
        r_avg_list="$r_avg_list $r_avg"
        r_p99_list="$r_p99_list $r_p99"
        w_avg_list="$w_avg_list $w_avg"
        w_p99_list="$w_p99_list $w_p99"

        echo "${label},${run_idx},${qps},${futex_count},${futex_per_sec},${futex_per_op},${r_avg},${r_p99},${w_avg},${w_p99}" \
            >> "$RESULT_DIR/raw.csv"
    done

    local mean_qps _med_qps _sd_qps cv_qps mean_fps mean_fpo
    read mean_qps _med_qps _sd_qps cv_qps <<< "$(compute_stats $qps_list)"
    mean_fps=$(compute_mean $futex_per_sec_list)
    mean_fpo=$(compute_mean $futex_per_op_list)

    printf "    STATS: QPS_mean=%.0f  cv=%.2f%%  futex/sec=%.1f  futex/op=%s\n" \
        "$mean_qps" "$cv_qps" "$mean_fps" "$mean_fpo"

    echo "| $label | $mean_qps | $mean_fps | $mean_fpo | $cv_qps | $RUNS |" \
        >> "$RESULT_DIR/summary.md"

    cleanup; sleep 1
}

# --- master baseline ---
run_one_pause "master" "$MEMCACHED_MASTER_BIN" 0

# --- pause-spinlock sweep ---
for pause_count in $PAUSE_VALUES; do
    run_one_pause "pause=${pause_count}" "$MEMCACHED_BIN" "$pause_count"
done

echo ""
echo "============================================================"
echo " FINAL SUMMARY"
echo "============================================================"
cat "$RESULT_DIR/summary.md"
echo ""
echo "Results: $RESULT_DIR"
