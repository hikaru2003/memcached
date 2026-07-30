#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   bash experiment/run_handoff_sweep.sh
#
# Description:
#   PAUSE count N を変えながらロックハンドオフレイテンシを計測する。
#   各N値について RUNS ラン計測し、全ラン後に SIGUSR2 で
#   handoff_samples_thread*.bin をダンプして RESULT_DIR/N<n>/ に収集する。
#
# Parameters (env vars):
#   MEMCACHED_BIN          - handoff-latency計測バイナリ       (default: ./memcached_handoff_debug)
#   MUTILATE_BIN           - mutilateバイナリ                  (default: ../mutilate/mutilate_p999)
#   MC_THREADS             - memcachedワーカースレッド数        (default: 4)
#   MUT_THREADS            - mutilateクライアントスレッド数      (default: 4)
#   MUT_CONNS              - mutilate コネクション/スレッド      (default: 1)
#   DEPTH                  - mutilate pipeline depth            (default: 32)
#   RECORDS                - key range                          (default: 1)
#   UPDATE_RATIO           - SET割合                            (default: 0.5)
#   WARMUP_SEC             - warmup秒数                        (default: 150)
#   DURATION               - 計測秒数（1ランあたり）            (default: 60)
#   RUNS                   - 各Nのラン数（handoff samplesを蓄積）(default: 5)
#   SPIN_ROUNDS            - trylock試行回数（固定）             (default: 30)
#   PAUSE_PER_ROUND_VALUES - N sweep値                         (default: 0-10全整数, N15, step-5 in 20-100, 150 200)
#   PORT                   - memcachedポート                   (default: 11222)
#   MC_CPUS                - memcached CPU affinity            (default: 0-3)
#   WL_CPUS                - mutilate CPU affinity             (default: 4-7)
#
# Output:
#   experiment/results/handoff_YYYYMMDD_HHMMSS/
#     run_info.md                           - 実験パラメータ
#     N<n>/handoff_samples_thread<t>.bin    - 各条件・スレッドのhandoffレイテンシサンプル（uint64_t, rdtscサイクル）
#     N<n>/stats.txt                        - mean QPS
#
# Prerequisites:
#   - ./memcached_handoff_debug: debug/handoff-latencyブランチのビルド
#   - ../mutilate/mutilate_p999 (or set MUTILATE_BIN)
#   - setup_perf_env.sh実施済み（SMT off / performance governor / turbo off）

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached_handoff_debug}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate_p999}"
MC_THREADS="${MC_THREADS:-4}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-1}"
DEPTH="${DEPTH:-32}"
RECORDS="${RECORDS:-1}"
UPDATE_RATIO="${UPDATE_RATIO:-0.5}"
WARMUP_SEC="${WARMUP_SEC:-150}"
DURATION="${DURATION:-60}"
RUNS="${RUNS:-5}"
SPIN_ROUNDS="${SPIN_ROUNDS:-30}"
PAUSE_PER_ROUND_VALUES="${PAUSE_PER_ROUND_VALUES:-0 1 2 3 4 5 6 7 8 9 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100 150 200}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"

# --- バイナリチェック ---
if [ ! -x "$MEMCACHED_BIN" ]; then
    echo "[ERROR] MEMCACHED_BIN not found: $MEMCACHED_BIN"
    echo "  Build: git checkout debug/handoff-latency && make && cp memcached memcached_handoff_debug"
    exit 1
fi
if [ ! -x "$MUTILATE_BIN" ]; then
    echo "[ERROR] MUTILATE_BIN not found: $MUTILATE_BIN"
    exit 1
fi
echo "[OK] All binaries found."

# --- CPU環境チェック ---
check_perf_env() {
    local errors=0
    local smt_val
    smt_val=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo "N/A")
    if [ "$smt_val" = "N/A" ]; then
        echo "[WARN] SMT status unknown"
    elif [ "$smt_val" != "0" ]; then
        echo "[ERROR] SMT is ON (expected: 0)"; errors=$(( errors + 1 ))
    fi

    local gov
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    if [ "$gov" = "N/A" ]; then
        echo "[WARN] governor unknown"
    elif [ "$gov" != "performance" ]; then
        echo "[ERROR] governor=$gov (expected: performance)"; errors=$(( errors + 1 ))
    fi

    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        local no_turbo
        no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
        [ "$no_turbo" != "1" ] && { echo "[ERROR] Turbo ON"; errors=$(( errors + 1 )); }
    elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        local boost_val
        boost_val=$(cat /sys/devices/system/cpu/cpufreq/boost)
        [ "$boost_val" != "0" ] && { echo "[ERROR] Turbo ON"; errors=$(( errors + 1 )); }
    else
        echo "[WARN] Turbo status unknown"
    fi

    if [ "$errors" -gt 0 ]; then
        echo "[ERROR] $errors env check(s) failed. Run: sudo bash experiment/setup_perf_env.sh"
        exit 1
    fi
    echo "[OK] CPU env: SMT=off, governor=performance, turbo=off"
}
check_perf_env

RUN_DATE=$(date '+%Y%m%d_%H%M%S')
RESULT_DIR="experiment/results/handoff_${RUN_DATE}"
mkdir -p "$RESULT_DIR"

n_vals=$(echo "$PAUSE_PER_ROUND_VALUES" | wc -w)
est_sec=$(( n_vals * (WARMUP_SEC + DURATION * RUNS) ))
est_min=$(( est_sec / 60 ))

{
    echo "# Run info (handoff latency sweep)"
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- bin: $MEMCACHED_BIN"
    echo "- mutilate_bin: $MUTILATE_BIN"
    echo "- mc_threads: $MC_THREADS (cpus: $MC_CPUS)"
    echo "- mut: -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- spin_rounds: $SPIN_ROUNDS (fixed)"
    echo "- pause_per_round values: $PAUSE_PER_ROUND_VALUES"
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
    local ppr=$1
    cleanup
    fuser -k "${PORT}"/tcp 2>/dev/null || true
    sleep 0.3
    MEMCACHED_SPIN_ROUNDS="$SPIN_ROUNDS" \
    MEMCACHED_PAUSE_PER_ROUND="$ppr" \
        taskset -c "$MC_CPUS" "$MEMCACHED_BIN" \
        -p "$PORT" -t "$MC_THREADS" -m 256 2>&1 &
    MC_PID=$!
    for _ in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  ppr=$ppr"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

run_one_config() {
    local label=$1 ppr=$2
    local out_dir="$RESULT_DIR/$label"
    mkdir -p "$out_dir"

    echo ""
    echo "=============================="
    echo " $label"
    echo "=============================="

    start_memcached "$ppr"

    echo "  warmup ${WARMUP_SEC}s ..."
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true

    # RUNS回連続計測。handoff samplesはリングバッファに蓄積し続ける
    local total_qps=0
    for run_idx in $(seq 1 "$RUNS"); do
        local qps
        qps=$(taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
            -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
            -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$DURATION" \
            2>/dev/null | grep "^Total QPS" | awk '{print $4}')
        printf "  run %d/%d: QPS=%s\n" "$run_idx" "$RUNS" "$qps"
        total_qps=$(awk "BEGIN{print $total_qps + ${qps:-0}}")
    done
    local mean_qps
    mean_qps=$(awk "BEGIN{printf \"%.0f\", $total_qps / $RUNS}")
    echo "  mean QPS: $mean_qps"

    # SIGUSR2 でハンドオフサンプルをダンプ
    kill -USR2 "$MC_PID"
    sleep 1
    if mv handoff_samples_thread*.bin "$out_dir/" 2>/dev/null; then
        local nfiles
        nfiles=$(ls "$out_dir"/handoff_samples_thread*.bin 2>/dev/null | wc -l)
        echo "  samples dumped: $nfiles files -> $out_dir/"
    else
        echo "[WARN] no handoff_samples_thread*.bin found for $label"
    fi

    echo "mean_qps=$mean_qps" > "$out_dir/stats.txt"
    cleanup; sleep 1
}

echo "============================================================"
echo " handoff latency sweep"
echo "============================================================"
echo " bin         : $MEMCACHED_BIN"
echo " mc_threads  : $MC_THREADS  cpus: $MC_CPUS"
echo " mut         : -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
echo " warmup      : ${WARMUP_SEC}s  measure: ${DURATION}s x ${RUNS} runs"
echo " SPIN_ROUNDS : $SPIN_ROUNDS"
echo " N values    : $PAUSE_PER_ROUND_VALUES"
echo " est_time    : ~${est_min} min"
echo " results     : $RESULT_DIR"
echo "============================================================"

for ppr in $PAUSE_PER_ROUND_VALUES; do
    run_one_config "N${ppr}" "$ppr"
done

echo ""
echo "============================================================"
echo " Done. Results: $RESULT_DIR"
echo "============================================================"
echo ""
echo "次のステップ:"
echo "  統計抽出: python3 experiment/extract_handoff_stats.py --dir $RESULT_DIR"
echo "  push    : EXPERIMENT_TYPE=handoff bash experiment/push_results.sh"
