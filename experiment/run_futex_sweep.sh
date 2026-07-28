#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   bash experiment/run_futex_sweep.sh
#
# Description:
#   PAUSE_PER_ROUND（N）を sweep しながら perf stat で futex syscall 回数を計測する。
#   「PAUSEが増えるとロック競合が減り futex 呼び出しが減少する」を定量化するためのスクリプト。
#   syscalls:sys_enter_futex は FUTEX_WAIT + FUTEX_WAKE 両方を含む。
#   アーキ非依存（Broadwell / Skylake ann / Emerald Rapids 共通で使用可）。
#
# Parameters (env vars):
#   MEMCACHED_BIN          - utdelay バイナリ                (default: ./memcached)
#   MEMCACHED_MASTER_BIN   - master バイナリ（スピンなし）    (default: ./memcached_master)
#   MUTILATE_BIN           - mutilate バイナリ（p999対応）    (default: ../mutilate/mutilate_p999)
#   MC_THREADS             - memcached ワーカースレッド数     (default: 4)
#   MUT_THREADS            - mutilate クライアントスレッド数  (default: 4)
#   MUT_CONNS              - mutilate コネクション/スレッド   (default: 1)
#   DEPTH                  - mutilate pipeline depth (-d)     (default: 32)
#   RECORDS                - key range (-r)                   (default: 1)
#   UPDATE_RATIO           - SET 割合 (-u)                    (default: 0.5)
#   WARMUP_SEC             - warmup 秒数                     (default: 150)
#   DURATION               - 計測秒数                        (default: 60)
#   RUNS                   - 各 N のラン数                    (default: 5)
#   SPIN_ROUNDS            - trylock 試行回数（固定）          (default: 30)
#   PAUSE_PER_ROUND_VALUES - N sweep 値                      (default: 0-10全整数, 15, step-5 in 20-100, 150 200)
#   PORT                   - memcached ポート                (default: 11222)
#   MC_CPUS                - memcached CPU affinity          (default: 0-3)
#   WL_CPUS                - mutilate CPU affinity           (default: 4-7)
#
# Output:
#   experiment/results/futex_YYYYMMDD_HHMMSS/
#     run_info.md                      - 実験パラメータ
#     summary.csv                      - N別 run毎の全データ
#     raw/perf_<label>_run<i>.txt     - perf stat 生ログ
#     raw/mut_<label>_run<i>.log      - mutilate 生ログ
#
# Prerequisites:
#   - setup_perf_env.sh 適用済み（SMT off, performance governor, turbo off）
#   - perf が利用可能かつ syscall tracepoint 権限あり
#     （kernel.perf_event_paranoid <= -1 or sudo）
#     Fix: sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid'

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached}"
MEMCACHED_MASTER_BIN="${MEMCACHED_MASTER_BIN:-./memcached_master}"
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

PERF_EVENT="syscalls:sys_enter_futex"
# libtraceevent 対応の perf バイナリ（/usr/bin/perf は tracepoint 非対応の場合あり）
PERF_BIN="${PERF_BIN:-/home/morisaki/linux/tools/perf/perf}"

# ---- CPU 環境チェック ----
check_perf_env() {
    local errors=0

    local smt_val
    smt_val=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo "N/A")
    if [ "$smt_val" = "N/A" ]; then
        echo "[WARN] SMT status unknown"
    elif [ "$smt_val" != "0" ]; then
        echo "[ERROR] SMT is ON (smt/active=$smt_val)"; errors=$(( errors + 1 ))
    fi

    local gov
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    if [ "$gov" != "N/A" ] && [ "$gov" != "performance" ]; then
        echo "[ERROR] governor=$gov (expected: performance)"; errors=$(( errors + 1 ))
    fi

    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        local no_turbo
        no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
        if [ "$no_turbo" != "1" ]; then
            echo "[ERROR] Turbo Boost is ON (no_turbo=$no_turbo)"; errors=$(( errors + 1 ))
        fi
    fi

    if [ "$errors" -gt 0 ]; then
        echo "[ERROR] $errors environment check(s) failed. Fix: sudo bash experiment/setup_perf_env.sh"
        exit 1
    fi
    echo "[OK] CPU env: SMT=off, governor=performance, turbo=off"
}

# ---- perf 権限チェック（tracepoint は paranoid <= -1 か sudo が必要）----
check_perf_perm() {
    local paranoid
    paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "N/A")
    echo "[INFO] perf_event_paranoid = $paranoid"

    # syscall tracepoint は paranoid > -1 だと非root では取れない
    if [ "$paranoid" != "N/A" ] && [ "$paranoid" -gt -1 ] 2>/dev/null; then
        echo "[WARN] perf_event_paranoid=$paranoid: syscall tracepoint には -1 以下が必要"
        echo "       Fix: sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid'"
    fi

    if [ ! -x "$PERF_BIN" ]; then
        echo "[ERROR] PERF_BIN が見つからない: $PERF_BIN"
        exit 1
    fi
    if "$PERF_BIN" stat -e "$PERF_EVENT" -- sleep 0.1 2>/dev/null; then
        PERF_CMD="$PERF_BIN"
    elif sudo "$PERF_BIN" stat -e "$PERF_EVENT" -- sleep 0.1 2>/dev/null; then
        echo "[INFO] perf は sudo で実行します"
        PERF_CMD="sudo $PERF_BIN"
    else
        echo "[ERROR] perf stat -e $PERF_EVENT が利用できない。権限を確認してください。"
        echo "       PERF_BIN=$PERF_BIN"
        exit 1
    fi
}

# ---- memcached 起動・停止 ----
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
    fuser -k "${PORT}"/tcp 2>/dev/null || true
    sleep 0.3
    if [ "$ppr" = "master" ]; then
        taskset -c "$MC_CPUS" "$bin" \
            -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
    else
        MEMCACHED_SPIN_ROUNDS="$SPIN_ROUNDS" \
        MEMCACHED_PAUSE_PER_ROUND="$ppr" \
            taskset -c "$MC_CPUS" "$bin" \
            -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
    fi
    MC_PID=$!
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  bin=$(basename "$bin")  ppr=$ppr"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

# ---- mutilate ログから QPS / p99 / p999 を抽出 ----
extract_qps()    { grep -E "^Total QPS" "$1" | awk '{print $4}'; }
extract_r_p99()  { grep -E "^read"   "$1" | awk '{print $10}'; }
extract_r_p999() { grep -E "^read"   "$1" | awk '{print $11}'; }

# ---- perf stat ログから値を抽出（--field-separator=, 形式）----
parse_perf_value() {
    local logfile=$1 event=$2
    grep -E ",${event}," "$logfile" 2>/dev/null \
        | grep -v "^#" \
        | head -1 \
        | cut -d',' -f1 \
        | tr -d ' '
}

# ---- 平均計算 ----
compute_mean() {
    echo "$@" | tr ' ' '\n' | awk 'NF{sum+=$1; n++} END { if(n>0) printf "%.2f", sum/n; else print "N/A" }'
}

# ---- 1設定の計測 ----
run_one_config() {
    local label=$1 bin=$2 ppr=$3
    local total_budget
    if [ "$ppr" = "master" ]; then total_budget=0
    else total_budget=$(( SPIN_ROUNDS * ppr )); fi

    echo ""
    echo "=============================="
    echo " $label  (pause_per_round=$ppr  total_budget=$total_budget)"
    echo "=============================="

    start_memcached "$bin" "$ppr"

    echo "    warmup ${WARMUP_SEC}s ..."
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true

    local qps_list="" r_p99_list="" r_p999_list="" futex_list=""

    for run_idx in $(seq 1 "$RUNS"); do
        local mut_log="$RESULT_DIR/raw/mut_${label}_run${run_idx}.log"
        local perf_log="$RESULT_DIR/raw/perf_${label}_run${run_idx}.txt"

        $PERF_CMD stat \
            -e "$PERF_EVENT" \
            -p "$MC_PID" \
            --field-separator=, \
            -o "$perf_log" \
            2>/dev/null &
        PERF_PID=$!

        taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
            -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
            -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$DURATION" \
            > "$mut_log" 2>&1

        kill -INT "$PERF_PID" 2>/dev/null
        wait "$PERF_PID" 2>/dev/null
        PERF_PID=""

        local qps r_p99 r_p999 futex_count
        qps=$(extract_qps    "$mut_log")
        r_p99=$(extract_r_p99  "$mut_log")
        r_p999=$(extract_r_p999 "$mut_log")
        futex_count=$(parse_perf_value "$perf_log" "syscalls:sys_enter_futex")

        # futex/req: スループット正規化（N変化でQPSも変わるため）
        local futex_per_req="N/A"
        if [ -n "$futex_count" ] && [ -n "$qps" ] && [ "$qps" != "0" ]; then
            futex_per_req=$(awk "BEGIN{printf \"%.6f\", $futex_count / ($qps * $DURATION)}")
        fi

        printf "    run %d/%d: QPS=%-8s  r_p99=%-6s  r_p999=%-6s  futex=%-10s  futex/req=%s\n" \
            "$run_idx" "$RUNS" "$qps" "$r_p99" "$r_p999" "${futex_count:-N/A}" "$futex_per_req"

        echo "${label},${ppr},${SPIN_ROUNDS},${total_budget},${run_idx},${qps},${r_p99},${r_p999},${futex_count:-N/A},${futex_per_req}" \
            >> "$RESULT_DIR/summary.csv"

        qps_list="$qps_list $qps"
        r_p99_list="$r_p99_list $r_p99"
        r_p999_list="$r_p999_list $r_p999"
        [ -n "${futex_count:-}" ] && futex_list="$futex_list $futex_count"
    done

    local mean_qps mean_r_p99 mean_r_p999 mean_futex
    mean_qps=$(compute_mean $qps_list)
    mean_r_p99=$(compute_mean $r_p99_list)
    mean_r_p999=$(compute_mean $r_p999_list)
    mean_futex=$(compute_mean ${futex_list:-0})

    printf "    SUMMARY: QPS_mean=%-8s  r_p99=%-6s  r_p999=%-6s  futex_mean=%s\n" \
        "$mean_qps" "$mean_r_p99" "$mean_r_p999" "$mean_futex"

    cleanup; sleep 1
}

# ---- メイン ----
check_perf_env
check_perf_perm

RUN_DATE=$(date '+%Y%m%d_%H%M%S')
RESULT_DIR="experiment/results/futex_${RUN_DATE}"
mkdir -p "$RESULT_DIR/raw"

n_vals=$(echo "$PAUSE_PER_ROUND_VALUES" | wc -w)
est_sec=$(( (n_vals + 1) * (WARMUP_SEC + DURATION * RUNS) ))
est_min=$(( est_sec / 60 ))

{
    echo "# Run info (futex sweep)"
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- utdelay_bin: $MEMCACHED_BIN"
    echo "- master_bin:  $MEMCACHED_MASTER_BIN"
    echo "- mutilate_bin: $MUTILATE_BIN"
    echo "- perf_event: $PERF_EVENT"
    echo "- mc_threads: $MC_THREADS (cpus: $MC_CPUS)"
    echo "- mut: -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- spin_rounds: $SPIN_ROUNDS (fixed)"
    echo "- pause_per_round values: $PAUSE_PER_ROUND_VALUES"
    echo "- est_time: ~${est_min} min"
} > "$RESULT_DIR/run_info.md"

echo "label,pause_per_round,spin_rounds,total_pause_budget,run,QPS,r_p99_us,r_p999_us,futex_count,futex_per_req" \
    > "$RESULT_DIR/summary.csv"

echo "============================================================"
echo " memcached futex sweep"
echo "============================================================"
echo " utdelay_bin : $MEMCACHED_BIN"
echo " master_bin  : $MEMCACHED_MASTER_BIN"
echo " mutilate    : $MUTILATE_BIN"
echo " perf event  : $PERF_EVENT"
echo " mc_threads  : $MC_THREADS  cpus: $MC_CPUS"
echo " mut         : -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
echo " warmup      : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " SPIN_ROUNDS : $SPIN_ROUNDS (fixed)"
echo " N values    : $PAUSE_PER_ROUND_VALUES"
echo " est_time    : ~${est_min} min"
echo " results     : $RESULT_DIR"
echo "============================================================"

# master baseline
if [ -x "$MEMCACHED_MASTER_BIN" ]; then
    run_one_config "master" "$MEMCACHED_MASTER_BIN" "master"
else
    echo "[WARN] master binary not found: $MEMCACHED_MASTER_BIN  skipping baseline"
fi

# pause_per_round sweep
for ppr in $PAUSE_PER_ROUND_VALUES; do
    run_one_config "N${ppr}" "$MEMCACHED_BIN" "$ppr"
done

echo ""
echo "============================================================"
echo " 完了"
echo " results: $RESULT_DIR"
echo " summary: $RESULT_DIR/summary.csv"
echo "============================================================"
