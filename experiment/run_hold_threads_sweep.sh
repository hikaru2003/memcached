#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   # デフォルト (N=0 固定, T=1/2/4 の 3 条件, 約 8 分)
#   bash experiment/run_hold_threads_sweep.sh
#
#   # N を変えて実施 (N=5 で 4 コア並列度の QPS peak 相当)
#   PAUSE_PER_ROUND_VALUES="5" bash experiment/run_hold_threads_sweep.sh
#
#   # 複数 N × 複数 T を横断 (例: N=0,5,200 × T=1,2,4 → 9 条件, 約 22 分)
#   PAUSE_PER_ROUND_VALUES="0 5 200" MC_THREADS_VALUES="1 2 4" \
#     bash experiment/run_hold_threads_sweep.sh
#
#   # T=8 も含める場合 (ann は 8 論理 CPU なので mutilate と共有: 精度低下注意)
#   MC_THREADS_VALUES="1 2 4 8" bash experiment/run_hold_threads_sweep.sh
#
# Description:
#   Phase 2: N を固定してスレッド数 (MC_THREADS) を変化させ、CS 長 (hold time) が
#   スレッド数増加に伴って伸びることを検証する実験。
#     - T=1 なら pingpong なしで L1 hit → 最短
#     - T=2 以上で他コアとの cacheline 争奪が発生 → 増加
#
#   全ラン後に SIGUSR2 で hold_samples_thread*.bin をダンプして
#   RESULT_DIR/N<n>_T<t>/ に収集する。
#
# Parameters (env vars):
#   MEMCACHED_BIN          - hold-time計測バイナリ           (default: ./memcached_hold_debug)
#   MUTILATE_BIN           - mutilateバイナリ                (default: ../mutilate/mutilate_p999)
#   MC_THREADS_VALUES      - memcachedワーカースレッド数リスト (default: "1 2 4")
#   PAUSE_PER_ROUND_VALUES - N 値リスト                     (default: "0")
#   MUT_THREADS            - mutilateクライアントスレッド数   (default: 4)
#   MUT_CONNS              - mutilate コネクション/スレッド   (default: 1)
#   DEPTH                  - mutilate pipeline depth         (default: 32)
#   RECORDS                - key range                       (default: 1)
#   UPDATE_RATIO           - SET割合                         (default: 0.5)
#   WARMUP_SEC             - warmup秒数                      (default: 60)
#   DURATION               - 計測秒数（1ランあたり）         (default: 30)
#   RUNS                   - 各条件のラン数                   (default: 3)
#   SPIN_ROUNDS            - trylock試行回数（固定）          (default: 30)
#   PORT                   - memcachedポート                (default: 11222)
#
# CPU affinity 割り当てポリシー:
#   T=1: MC=0,     WL=4-7
#   T=2: MC=0-1,   WL=4-7
#   T=4: MC=0-3,   WL=4-7
#   T=8: MC=0-7,   WL=0-7  ← mutilate と共有、負荷分離できない (要注意)
#
# Output:
#   experiment/results/hold_threads_YYYYMMDD_HHMMSS/
#     run_info.md                              - 実験パラメータ
#     run.log                                  - スクリプト完全ログ
#     N<n>_T<t>/hold_samples_thread<i>.bin     - 各条件・スレッドの CS 長サンプル
#     N<n>_T<t>/stats.txt                      - mean QPS
#
# Prerequisites:
#   - ./memcached_hold_debug: debug/hold-time-v2 ブランチのビルド
#   - ../mutilate/mutilate_p999
#   - setup_perf_env.sh 実施済み (ann は BIOS 側で対応済み)

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached_hold_debug}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate_p999}"
MC_THREADS_VALUES="${MC_THREADS_VALUES:-1 2 4}"
PAUSE_PER_ROUND_VALUES="${PAUSE_PER_ROUND_VALUES:-0}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-1}"
DEPTH="${DEPTH:-32}"
RECORDS="${RECORDS:-1}"
UPDATE_RATIO="${UPDATE_RATIO:-0.5}"
WARMUP_SEC="${WARMUP_SEC:-60}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-3}"
SPIN_ROUNDS="${SPIN_ROUNDS:-30}"
PORT="${PORT:-11222}"

# --- CPU affinity 動的割り当て ---
compute_cpu_affinity() {
    local T=$1
    case "$T" in
        1) MC_CPUS="0";   WL_CPUS="4-7" ;;
        2) MC_CPUS="0-1"; WL_CPUS="4-7" ;;
        3) MC_CPUS="0-2"; WL_CPUS="4-7" ;;
        4) MC_CPUS="0-3"; WL_CPUS="4-7" ;;
        5) MC_CPUS="0-4"; WL_CPUS="5-7" ;;
        6) MC_CPUS="0-5"; WL_CPUS="6-7" ;;
        7) MC_CPUS="0-6"; WL_CPUS="7" ;;
        8) MC_CPUS="0-7"; WL_CPUS="0-7" ;;  # 8論理CPUで共有 (精度低下)
        *) echo "[ERROR] unsupported T=$T (must be 1..8 on ann)"; return 1 ;;
    esac
}

# --- バイナリチェック ---
if [ ! -x "$MEMCACHED_BIN" ]; then
    echo "[ERROR] MEMCACHED_BIN not found: $MEMCACHED_BIN"; exit 1
fi
if [ ! -x "$MUTILATE_BIN" ]; then
    echo "[ERROR] MUTILATE_BIN not found: $MUTILATE_BIN"; exit 1
fi
echo "[OK] All binaries found."

# --- 結果ディレクトリを先に作成し、以降の全出力をログファイルにも保存 ---
RUN_DATE=$(date '+%Y%m%d_%H%M%S')
RESULT_DIR="experiment/results/hold_threads_${RUN_DATE}"
mkdir -p "$RESULT_DIR"
LOG_FILE="$RESULT_DIR/run.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[log] full output is being saved to: $LOG_FILE"

# --- CPU環境チェック (Phase 1 と同じロジック) ---
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
        echo "[ERROR] $errors env check(s) failed."
        exit 1
    fi
    echo "[OK] CPU env: SMT=off, turbo=off"
}
check_perf_env

n_t=$(echo "$PAUSE_PER_ROUND_VALUES" | wc -w)
n_mc=$(echo "$MC_THREADS_VALUES" | wc -w)
total=$(( n_t * n_mc ))
est_sec=$(( total * (WARMUP_SEC + DURATION * RUNS) ))
est_min=$(( est_sec / 60 ))

{
    echo "# Run info (hold time / thread sweep at fixed N)"
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- bin: $MEMCACHED_BIN"
    echo "- mutilate_bin: $MUTILATE_BIN"
    echo "- MC_THREADS values: $MC_THREADS_VALUES"
    echo "- PAUSE_PER_ROUND values (N): $PAUSE_PER_ROUND_VALUES"
    echo "- mut: -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- spin_rounds: $SPIN_ROUNDS (fixed)"
    echo "- total conditions: $total  est_time: ~${est_min} min"
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
    local ppr=$1 T=$2
    cleanup
    fuser -k "${PORT}"/tcp 2>/dev/null || true
    sleep 0.3
    MEMCACHED_SPIN_ROUNDS="$SPIN_ROUNDS" \
    MEMCACHED_PAUSE_PER_ROUND="$ppr" \
        taskset -c "$MC_CPUS" "$MEMCACHED_BIN" \
        -p "$PORT" -t "$T" -m 256 2>&1 &
    MC_PID=$!
    for _ in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  T=$T  MC_CPUS=$MC_CPUS  WL_CPUS=$WL_CPUS  N=$ppr"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

run_one_config() {
    local label=$1 ppr=$2 T=$3
    local out_dir="$RESULT_DIR/$label"
    mkdir -p "$out_dir"

    echo ""
    echo "=============================="
    echo " $label   (T=$T, N=$ppr)"
    echo "=============================="

    compute_cpu_affinity "$T" || return 1
    start_memcached "$ppr" "$T"

    echo "  warmup ${WARMUP_SEC}s ..."
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true

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

    kill -USR2 "$MC_PID"
    sleep 1
    if mv hold_samples_thread*.bin "$out_dir/" 2>/dev/null; then
        local nfiles
        nfiles=$(ls "$out_dir"/hold_samples_thread*.bin 2>/dev/null | wc -l)
        echo "  samples dumped: $nfiles files -> $out_dir/"
    else
        echo "[WARN] no hold_samples_thread*.bin found for $label"
    fi
    mv hold_counts.txt "$out_dir/" 2>/dev/null || echo "[WARN] no hold_counts.txt for $label"

    echo "mean_qps=$mean_qps" > "$out_dir/stats.txt"
    echo "mc_threads=$T"     >> "$out_dir/stats.txt"
    echo "pause_per_round=$ppr" >> "$out_dir/stats.txt"
    echo "mc_cpus=$MC_CPUS"  >> "$out_dir/stats.txt"
    echo "wl_cpus=$WL_CPUS"  >> "$out_dir/stats.txt"
    cleanup; sleep 1
}

echo "============================================================"
echo " hold time (CS length) sweep over MC_THREADS at fixed N"
echo "============================================================"
echo " bin              : $MEMCACHED_BIN"
echo " MC_THREADS values: $MC_THREADS_VALUES"
echo " N (PAUSE) values : $PAUSE_PER_ROUND_VALUES"
echo " mut              : -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
echo " warmup           : ${WARMUP_SEC}s  measure: ${DURATION}s x ${RUNS} runs"
echo " SPIN_ROUNDS      : $SPIN_ROUNDS"
echo " total conditions : $total   est_time: ~${est_min} min"
echo " results          : $RESULT_DIR"
echo "============================================================"

# T=8 の警告
for T in $MC_THREADS_VALUES; do
    if [ "$T" = "8" ]; then
        echo ""
        echo "[WARN] T=8 detected: ann is 8 logical CPUs. memcached will use CPU 0-7 (all cores)"
        echo "       and mutilate will share the same CPUs. CS length measurement will include"
        echo "       mutilate interference. Interpret T=8 results with caution."
    fi
done

for ppr in $PAUSE_PER_ROUND_VALUES; do
    for T in $MC_THREADS_VALUES; do
        run_one_config "N${ppr}_T${T}" "$ppr" "$T"
    done
done

echo ""
echo "============================================================"
echo " Done. Results: $RESULT_DIR"
echo "============================================================"
echo ""
echo "次のステップ:"
echo "  統計抽出: python3 experiment/extract_hold_stats.py --dir $RESULT_DIR"
echo "  (注: N<n>_T<t> 形式のディレクトリ名を extract 側も対応する必要あり)"
