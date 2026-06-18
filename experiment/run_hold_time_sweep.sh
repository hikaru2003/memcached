#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_hold_time_sweep.sh
#
# Description:
#   PAUSE_COUNT を sweep しながら spinlock の平均ロック保持時間（avg_cycles）を計測する。
#   avg_cycles は PAUSE_COUNT によらず一定であることを確認する検証実験。
#   master バイナリ（pthread_mutex のみ）でも同じ計測を行い比較する。
#
#   SIGUSR2 出力フォーマット: SPINLOCK_HOLD_CYCLES: <total_cycles> <lock_count> <avg_cycles>
#
# Parameters (env vars):
#   MEMCACHED_BIN        - pause-spinlock debug バイナリ   (default: ./memcached_debug_hold)
#   MEMCACHED_MASTER_BIN - master debug バイナリ           (default: ./memcached_debug_hold_master)
#   MUTILATE_BIN         - mutilate バイナリ               (default: ../mutilate/mutilate)
#   MC_THREADS           - memcached ワーカースレッド数     (default: 4)
#   MUT_THREADS          - mutilate クライアントスレッド数  (default: 4)
#   MUT_CONNS            - mutilate コネクション/スレッド   (default: 1)
#   DEPTH                - mutilate pipeline depth          (default: 32)
#   PAUSE_VALUES         - PAUSE_COUNT sweep 値            (default: "0 10 20 30 40 50 60 70 80 90 100 200 300")
#   RECORDS              - key range                        (default: 1)
#   UPDATE_RATIO         - SET 割合                         (default: 0.5)
#   WARMUP_SEC           - warmup 秒数                      (default: 10)
#   DURATION             - 計測秒数                         (default: 10)
#   PORT                 - memcached ポート                 (default: 11222)
#   MC_CPUS              - memcached CPU affinity           (default: 0-3)
#   WL_CPUS              - mutilate CPU affinity            (default: 4-7)
#
# Output:
#   experiment/results/debug_hold_time_mc{MC}_mut{MUT}/
#     run_info.md  - 実験パラメータ
#     summary.md   - PAUSE別 avg_cycles テーブル（master 含む）
#     raw.csv      - label,avg_cycles,lock_count,avg_ns の生データ
#
# Prerequisites:
#   - ./memcached_debug_hold: debug/hold-time ブランチのビルド
#   - ./memcached_debug_hold_master: debug/hold-time-master ブランチのビルド
#   - mutilate binary at ../mutilate/mutilate (or set MUTILATE_BIN)

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached_debug_hold}"
MEMCACHED_MASTER_BIN="${MEMCACHED_MASTER_BIN:-./memcached_debug_hold_master}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
MC_THREADS="${MC_THREADS:-4}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-1}"
DEPTH="${DEPTH:-32}"
PAUSE_VALUES="${PAUSE_VALUES:-0 10 20 30 40 50 60 70 80 90 100 200 300}"
RECORDS="${RECORDS:-1}"
UPDATE_RATIO="${UPDATE_RATIO:-0.5}"
WARMUP_SEC="${WARMUP_SEC:-10}"
DURATION="${DURATION:-10}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"

_BASE="experiment/results/debug_hold_time_mc${MC_THREADS}_mut${MUT_THREADS}"
RESULT_DIR="$_BASE"
_i=2; while [ -d "$RESULT_DIR" ]; do RESULT_DIR="${_BASE}_run${_i}"; _i=$((_i+1)); done
mkdir -p "$RESULT_DIR"

MC_PID=""
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
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then return 0; fi
    done
    echo "[ERROR] memcached did not start" >&2; return 1
}

measure_one() {
    local log=$1
    # warmup
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true
    # reset
    kill -USR2 "$MC_PID" 2>/dev/null; sleep 0.2
    # measure
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$DURATION" \
        > /dev/null 2>&1 || true
    # read
    kill -USR2 "$MC_PID" 2>/dev/null; sleep 0.2

    local line avg count
    line=$(grep "SPINLOCK_HOLD_CYCLES:" "$log" | tail -1)
    avg=$(echo "$line" | awk '{print $4}')
    count=$(echo "$line" | awk '{print $3}')
    local avg_ns
    avg_ns=$(awk "BEGIN { printf \"%.1f\", ${avg:-0} / 2.1 }")
    printf "%-14s %15s %15s %15s\n" "$1_label" "${avg:-N/A}" "${count:-N/A}" "$avg_ns"
}

{
    echo "# Run info (hold-time sweep)"
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- spinlock_bin: $MEMCACHED_BIN"
    echo "- master_bin: $MEMCACHED_MASTER_BIN"
    echo "- mc_threads: $MC_THREADS"
    echo "- mut: -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH"
    echo "- records: $RECORDS  update_ratio: $UPDATE_RATIO"
    echo "- warmup: ${WARMUP_SEC}s  duration: ${DURATION}s"
    echo "- pause_values: $PAUSE_VALUES"
} > "$RESULT_DIR/run_info.md"

{
    echo "# hold-time sweep / mc=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -d ${DEPTH} -r ${RECORDS} -u ${UPDATE_RATIO}"
    echo ""
    echo "avg_cycles = total_hold_cycles / lock_count (rdtsc, both spin and futex paths)"
    echo "master = pthread_mutex のみ（スピンなし）"
    echo ""
    echo "| label | avg_cycles | lock_count | avg_ns(2.1GHz) |"
    echo "|---|---|---|---|"
} > "$RESULT_DIR/summary.md"

echo "label,avg_cycles,lock_count,avg_ns_3ghz" > "$RESULT_DIR/raw.csv"

echo "============================================================"
echo " hold-time sweep  (SIGUSR2 / rdtsc)"
echo "============================================================"
echo " pause_values: $PAUSE_VALUES"
echo " warmup: ${WARMUP_SEC}s  measure: ${DURATION}s"
echo " records: $RECORDS  update_ratio: $UPDATE_RATIO"
echo " results: $RESULT_DIR"
echo ""
printf "%-14s %15s %15s %15s\n" "label" "avg_cycles" "lock_count" "avg_ns(2.1GHz)"
printf "%-14s %15s %15s %15s\n" "-----" "----------" "----------" "------------"

# --- master baseline (PAUSE_COUNT は無効、pthread_mutex のみ) ---
log=$(mktemp /tmp/mc_hold_XXXXXX.log)
start_memcached "$MEMCACHED_MASTER_BIN" 0 "$log"

taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
    -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
    -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$WARMUP_SEC" \
    > /dev/null 2>&1 || true
kill -USR2 "$MC_PID" 2>/dev/null; sleep 0.2
taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
    -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
    -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$DURATION" \
    > /dev/null 2>&1 || true
kill -USR2 "$MC_PID" 2>/dev/null; sleep 0.2

line=$(grep "SPINLOCK_HOLD_CYCLES:" "$log" | tail -1)
avg=$(echo "$line" | awk '{print $4}')
count=$(echo "$line" | awk '{print $3}')
avg_ns=$(awk "BEGIN { printf \"%.1f\", ${avg:-0} / 2.1 }")
printf "%-14s %15s %15s %15s\n" "master" "${avg:-N/A}" "${count:-N/A}" "$avg_ns"
echo "| master | ${avg:-N/A} | ${count:-N/A} | $avg_ns |" >> "$RESULT_DIR/summary.md"
echo "master,${avg:-0},${count:-0},$avg_ns" >> "$RESULT_DIR/raw.csv"
rm -f "$log"; cleanup; sleep 0.5

# --- pause-spinlock sweep ---
for pause in $PAUSE_VALUES; do
    log=$(mktemp /tmp/mc_hold_XXXXXX.log)
    start_memcached "$MEMCACHED_BIN" "$pause" "$log"

    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true
    kill -USR2 "$MC_PID" 2>/dev/null; sleep 0.2
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$DURATION" \
        > /dev/null 2>&1 || true
    kill -USR2 "$MC_PID" 2>/dev/null; sleep 0.2

    line=$(grep "SPINLOCK_HOLD_CYCLES:" "$log" | tail -1)
    avg=$(echo "$line" | awk '{print $4}')
    count=$(echo "$line" | awk '{print $3}')
    avg_ns=$(awk "BEGIN { printf \"%.1f\", ${avg:-0} / 2.1 }")
    printf "%-14s %15s %15s %15s\n" "pause=$pause" "${avg:-N/A}" "${count:-N/A}" "$avg_ns"
    echo "| pause=$pause | ${avg:-N/A} | ${count:-N/A} | $avg_ns |" >> "$RESULT_DIR/summary.md"
    echo "pause=$pause,${avg:-0},${count:-0},$avg_ns" >> "$RESULT_DIR/raw.csv"

    rm -f "$log"; cleanup; sleep 0.5
done

echo ""
echo "Results: $RESULT_DIR"
echo "master と pause sweep の avg_cycles がほぼ一致すれば計測は正しい。"
