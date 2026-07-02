#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   bash experiment/run_wait_distribution.sh
#
# Parameters (env vars):
#   MEMCACHED_BIN          - wait-time計測バイナリ        (default: ./memcached_wait_debug)
#   MEMCACHED_MASTER_BIN   - masterバイナリ（スピンなし）  (default: ./memcached_master)
#   MUTILATE_BIN           - mutilateバイナリ             (default: ../mutilate/mutilate)
#   MC_THREADS             - memcachedワーカースレッド数   (default: 4)
#   MUT_THREADS            - mutilateクライアントスレッド数 (default: 4)
#   MUT_CONNS              - mutilate コネクション/スレッド (default: 1)
#   DEPTH                  - mutilate pipeline depth       (default: 32)
#   RECORDS                - key range                     (default: 1)
#   UPDATE_RATIO           - SET割合                       (default: 0.5)
#   WARMUP_SEC             - warmup秒数                   (default: 300)
#   DURATION               - 計測秒数                      (default: 60)
#   RUNS                   - 各Nのラン数（wait samplesを蓄積） (default: 5)
#   SPIN_ROUNDS            - trylock試行回数（固定）         (default: 30)
#   PAUSE_PER_ROUND_VALUES - N sweep値                    (default: 0 2 4 10 30 100 200)
#   PORT                   - memcachedポート               (default: 11222)
#   MC_CPUS                - memcached CPU affinity        (default: 0-3)
#   WL_CPUS                - mutilate CPU affinity         (default: 4-7)
#
# Output:
#   experiment/results/wait_dist_YYYYMMDD_HHMMSS/
#     run_info.md                        - 実験パラメータ
#     N<n>/wait_samples_thread<t>.bin    - 各条件・スレッドのwait時間サンプル（uint64_t, rdtsxサイクル）
#     wait_distribution.png              - 全条件のPDF/CDFグラフ（plot_wait_distribution.pyが生成）
#
# Prerequisites:
#   - ./memcached_wait_debug: debug/wait-timeブランチのビルド
#   - ./memcached_master: masterブランチのビルド
#   - mutilate binary at ../mutilate/mutilate (or set MUTILATE_BIN)
#   - setup_perf_env.sh実施済み（SMT off / performance governor / turbo off）

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached_wait_debug}"
MEMCACHED_MASTER_BIN="${MEMCACHED_MASTER_BIN:-./memcached_master}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
MC_THREADS="${MC_THREADS:-4}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-1}"
DEPTH="${DEPTH:-32}"
RECORDS="${RECORDS:-1}"
UPDATE_RATIO="${UPDATE_RATIO:-0.5}"
WARMUP_SEC="${WARMUP_SEC:-300}"
DURATION="${DURATION:-60}"
RUNS="${RUNS:-5}"
SPIN_ROUNDS="${SPIN_ROUNDS:-30}"
PAUSE_PER_ROUND_VALUES="${PAUSE_PER_ROUND_VALUES:-0 2 4 10 30 100 200}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"

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
RESULT_DIR="experiment/results/wait_dist_${RUN_DATE}"
mkdir -p "$RESULT_DIR"

n_vals=$(echo "$PAUSE_PER_ROUND_VALUES" | wc -w)
# master + N values、各条件: warmup + RUNS×DURATION
est_sec=$(( (n_vals + 1) * (WARMUP_SEC + DURATION * RUNS) ))
est_min=$(( est_sec / 60 ))

{
    echo "# Run info (wait-time distribution sweep)"
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- bin: $MEMCACHED_BIN"
    echo "- master_bin: $MEMCACHED_MASTER_BIN"
    echo "- mc_threads: $MC_THREADS (cpus: $MC_CPUS)"
    echo "- mut: -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- spin_rounds: $SPIN_ROUNDS"
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
    local bin=$1 ppr=$2
    cleanup
    if [ "$ppr" = "master" ]; then
        taskset -c "$MC_CPUS" "$bin" \
            -p "$PORT" -t "$MC_THREADS" -m 256 2>&1 &
    else
        MEMCACHED_SPIN_ROUNDS="$SPIN_ROUNDS" \
        MEMCACHED_PAUSE_PER_ROUND="$ppr" \
            taskset -c "$MC_CPUS" "$bin" \
            -p "$PORT" -t "$MC_THREADS" -m 256 2>&1 &
    fi
    MC_PID=$!
    for _ in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  bin=$(basename "$bin")  ppr=$ppr"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

run_one_config() {
    local label=$1 bin=$2 ppr=$3
    local out_dir="$RESULT_DIR/$label"
    mkdir -p "$out_dir"

    echo ""
    echo "=============================="
    echo " $label"
    echo "=============================="

    start_memcached "$bin" "$ppr"

    echo "  warmup ${WARMUP_SEC}s ..."
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true

    # RUNS回連続計測。wait_samplesはmemcached内のリングバッファに蓄積し続け、
    # 全RUNSラン完了後に1回だけSIGUSR2でダンプする
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

    # wait samplesをダンプしてout_dirに移動
    # masterバイナリにはSIGUSR2ハンドラがないためスキップ
    if [ "$ppr" != "master" ]; then
        kill -USR2 "$MC_PID"
        sleep 1
        mv wait_samples_thread*.bin "$out_dir/" 2>/dev/null || \
            echo "[WARN] no sample files found for $label"
    fi

    echo "  mean_qps=$mean_qps" > "$out_dir/stats.txt"
    echo "  samples dumped to $out_dir/"

    cleanup; sleep 1
}

echo "============================================================"
echo " wait-time distribution sweep"
echo "============================================================"
echo " bin         : $MEMCACHED_BIN"
echo " master_bin  : $MEMCACHED_MASTER_BIN"
echo " mc_threads  : $MC_THREADS  cpus: $MC_CPUS"
echo " mut         : -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
echo " warmup      : ${WARMUP_SEC}s  measure: ${DURATION}s x ${RUNS} runs"
echo " SPIN_ROUNDS : $SPIN_ROUNDS"
echo " N values    : $PAUSE_PER_ROUND_VALUES"
echo " est_time    : ~${est_min} min"
echo " results     : $RESULT_DIR"
echo "============================================================"

# master baseline（スピンなし：wait_samplesバッファは確保されるが記録されない）
if [ -x "$MEMCACHED_MASTER_BIN" ]; then
    run_one_config "master" "$MEMCACHED_MASTER_BIN" "master"
else
    echo "[WARN] master binary not found: $MEMCACHED_MASTER_BIN  skipping"
fi

for ppr in $PAUSE_PER_ROUND_VALUES; do
    run_one_config "N${ppr}" "$MEMCACHED_BIN" "$ppr"
done

echo ""
echo "============================================================"
echo " グラフ生成"
echo "============================================================"
python3 experiment/plot_wait_distribution.py \
    --dir "$RESULT_DIR" \
    --max-us 20 \
    2>&1

echo ""
echo "Done. Results: $RESULT_DIR"
