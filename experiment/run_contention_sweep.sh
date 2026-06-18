#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_contention_sweep.sh
#
# Description:
#   get50_set50 (-r 1) の各 pause_count について lock contention 指標を計測する。
#
#   計測項目 (各 pause_count × RUNS 回の平均):
#     [Method B] perf stat:
#       - context-switches     : スレッドブロック発生数
#       - cpu-migrations       : CPUコア間のマイグレーション数
#       - cycles / instructions: CPU使用効率
#     [Method C] /proc/[pid]/status:
#       - voluntary_ctxt_switches   : 自発的CS (futex wait 等)
#       - nonvoluntary_ctxt_switches: 非自発的CS (タイムスライス)
#     [補助] /proc/[pid]/stat:
#       - stime delta          : kernel mode 滞在時間 (futex syscall の proxy)
#       - utime delta          : user mode 滞在時間 (spin 時間の proxy)
#
# Parameters (env vars):
#   MEMCACHED_BIN  - memcached binary path        (default: ./memcached)
#   MUTILATE_BIN   - mutilate binary path         (default: ../mutilate/mutilate)
#   PAUSE_VALUES   - space-separated pause counts (default: "0 10 30 50 70 100")
#   WARMUP_SEC     - warmup duration in seconds   (default: 60)
#   DURATION       - measurement duration (sec)   (default: 30)
#   RUNS           - runs per pause_count         (default: 3)
#   MC_THREADS     - memcached worker threads     (default: 32)
#   MUT_THREADS    - mutilate client threads      (default: 4)
#   MUT_CONNS      - mutilate connections/thread  (default: 4)
#   PORT           - memcached port               (default: 11222)
#
# Output:
#   experiment/results/contention_sweep_get50set50_YYYYMMDD_HHMMSS/
#     summary.md         - pause_count 別 contention 指標テーブル
#     raw.csv            - 全ラン生データ
#     run_P{pc}_{run}.log       - mutilate ログ
#     perf_P{pc}_{run}.txt      - perf stat 出力
#
# Prerequisites:
#   - memcached built from experiment/pause-spinlock branch
#   - perf installed (perf --version)
#   - mutilate binary

set -uo pipefail

MEMCACHED_BIN="${MEMCACHED_BIN:-./memcached}"
MUTILATE_BIN="${MUTILATE_BIN:-../mutilate/mutilate}"
PAUSE_VALUES="${PAUSE_VALUES:-0 10 30 50 70 100}"
WARMUP_SEC="${WARMUP_SEC:-60}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-3}"
MC_THREADS="${MC_THREADS:-8}"
MUT_THREADS="${MUT_THREADS:-4}"
MUT_CONNS="${MUT_CONNS:-4}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"
RECORDS=1
UPDATE_RATIO=0.5

RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
_BASE="experiment/results/contention_sweep_get50set50_mc${MC_THREADS}_mut${MUT_THREADS}c${MUT_CONNS}"
RESULT_DIR="$_BASE"
_i=2; while [ -d "$RESULT_DIR" ]; do RESULT_DIR="${_BASE}_run${_i}"; _i=$((_i+1)); done
mkdir -p "$RESULT_DIR/raw"
{
    echo "# Run info"
    echo "- date: ${RUN_DATE}"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- mc_threads: $MC_THREADS / mut_threads: $MUT_THREADS / mut_conns: $MUT_CONNS"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- pause_values: $PAUSE_VALUES"
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
    local pause_count=$1; cleanup
    MEMCACHED_PAUSE_COUNT=$pause_count \
        taskset -c "$MC_CPUS" "$MEMCACHED_BIN" -p "$PORT" -t "$MC_THREADS" -m 256 -u nobody 2>&1 &
    MC_PID=$!
    for i in $(seq 1 10); do
        sleep 0.5
        if ss -tnlp 2>/dev/null | grep -q ":$PORT"; then
            echo "[mc] PID=$MC_PID  PAUSE_COUNT=$pause_count  (port $PORT ready)"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

read_proc_status() {
    local pid=$1
    grep -E "^(voluntary|nonvoluntary)_ctxt_switches" /proc/$pid/status \
        | awk '{print $2}' | tr '\n' ' '
}

read_proc_stat_times() {
    # returns "utime stime" in clock ticks (field 14, 15)
    local pid=$1
    awk '{print $14, $15}' /proc/$pid/stat
}

compute_mean() {
    echo "$@" | tr ' ' '\n' | awk 'NF{s+=$1;c++} END{printf "%.1f", c>0 ? s/c : 0}'
}
compute_mean_int() {
    echo "$@" | tr ' ' '\n' | awk 'NF{s+=$1;c++} END{printf "%d", c>0 ? int(s/c+0.5) : 0}'
}

CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)

echo "============================================================"
echo " memcached contention sweep (get50_set50, -r 1)"
echo "============================================================"
echo " binary    : $MEMCACHED_BIN"
echo " warmup    : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " PAUSE vals: $PAUSE_VALUES"
echo " CLK_TCK   : $CLK_TCK"
echo " results   : $RESULT_DIR"
echo "============================================================"

{
    echo "# contention sweep / get50_set50 / t=${MC_THREADS} / mutilate -T ${MUT_THREADS} -c ${MUT_CONNS} -r ${RECORDS} -u ${UPDATE_RATIO}"
    echo "# Method B: perf stat (context-switches, cpu-migrations, cycles, instructions)"
    echo "# Method C: /proc/[pid]/status (voluntary / nonvoluntary ctx switches)"
    echo "# Auxiliary: /proc/[pid]/stat stime delta (kernel time, futex proxy)"
    echo ""
    echo "| pause_count | QPS | vol_cs/s | nonvol_cs/s | perf_cs/s | cpu_migr/s | stime_pct | utime_pct | ipc | n |"
    echo "|---|---|---|---|---|---|---|---|---|---|"
} > "$RESULT_DIR/summary.md"

echo "pause_count,run,QPS,vol_cs,nonvol_cs,perf_cs,cpu_migr,stime_ticks,utime_ticks" \
    > "$RESULT_DIR/raw.csv"

for pause_count in $PAUSE_VALUES; do
    echo ""
    echo ">>> PAUSE_COUNT=$pause_count"
    start_memcached "$pause_count"
    echo "    warmup ${WARMUP_SEC}s ..."
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -t "$WARMUP_SEC" > /dev/null 2>&1 || true

    qps_list=""
    vol_cs_list="" nonvol_cs_list=""
    perf_cs_list="" cpu_migr_list=""
    stime_list="" utime_list=""
    cycles_list="" instr_list=""

    for run_idx in $(seq 1 "$RUNS"); do
        logfile="$RESULT_DIR/raw/run_P${pause_count}_${run_idx}.log"
        perffile="$RESULT_DIR/raw/perf_P${pause_count}_${run_idx}.txt"

        # read /proc before
        read vol_before nonvol_before <<< "$(read_proc_status $MC_PID)"
        read ut_before st_before <<< "$(read_proc_stat_times $MC_PID)"

        # start mutilate in background
        taskset -c "$WL_CPUS" "$MUTILATE_BIN" -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
            -T "$MUT_THREADS" -c "$MUT_CONNS" -t "$DURATION" \
            > "$logfile" 2>&1 &
        MUT_PID=$!

        # perf stat attaches to memcached for DURATION seconds
        perf stat -p "$MC_PID" \
            -e context-switches,cpu-migrations,cycles,instructions \
            sleep "$DURATION" 2> "$perffile" || true

        wait "$MUT_PID" 2>/dev/null || true

        # read /proc after
        read vol_after nonvol_after <<< "$(read_proc_status $MC_PID)"
        read ut_after st_after <<< "$(read_proc_stat_times $MC_PID)"

        # extract QPS
        qps=$(grep -E "^Total QPS" "$logfile" | awk '{print $4}')

        # /proc deltas
        vol_delta=$((vol_after   - vol_before))
        nonvol_delta=$((nonvol_after - nonvol_before))
        st_delta=$((st_after - st_before))
        ut_delta=$((ut_after - ut_before))

        # per-second rates
        vol_rate=$(awk "BEGIN { printf \"%.0f\", $vol_delta   / $DURATION }")
        nonvol_rate=$(awk "BEGIN { printf \"%.0f\", $nonvol_delta / $DURATION }")

        # perf stat values from perffile
        perf_cs=$(awk '/context-switches/ {gsub(/,/,"",$1); print $1}' "$perffile" | head -1)
        perf_cs="${perf_cs:-0}"
        cpu_migr=$(awk '/cpu-migrations/  {gsub(/,/,"",$1); print $1}' "$perffile" | head -1)
        cpu_migr="${cpu_migr:-0}"
        cyc=$(awk '/cycles/              {gsub(/,/,"",$1); print $1}' "$perffile" | head -1)
        cyc="${cyc:-0}"
        ins=$(awk '/instructions/        {gsub(/,/,"",$1); print $1}' "$perffile" | head -1)
        ins="${ins:-0}"

        perf_cs_rate=$(awk "BEGIN { printf \"%.0f\", $perf_cs  / $DURATION }")
        migr_rate=$(awk  "BEGIN { printf \"%.0f\", $cpu_migr / $DURATION }")
        stime_pct=$(awk  "BEGIN { if ($st_delta>0) printf \"%.2f\", $st_delta / $CLK_TCK / $DURATION * 100; else print \"0.00\" }")
        utime_pct=$(awk  "BEGIN { if ($ut_delta>0) printf \"%.2f\", $ut_delta / $CLK_TCK / $DURATION * 100; else print \"0.00\" }")
        ipc=$(awk        "BEGIN { if ($cyc>0) printf \"%.3f\", $ins / $cyc; else print \"0.000\" }")

        printf "    run %d/%d: QPS=%.0f  vol_cs/s=%s  nonvol_cs/s=%s  perf_cs/s=%s  stime_pct=%s%%  utime_pct=%s%%  IPC=%s\n" \
            "$run_idx" "$RUNS" "$qps" "$vol_rate" "$nonvol_rate" "$perf_cs_rate" \
            "$stime_pct" "$utime_pct" "$ipc"

        qps_list="$qps_list $qps"
        vol_cs_list="$vol_cs_list $vol_rate"
        nonvol_cs_list="$nonvol_cs_list $nonvol_rate"
        perf_cs_list="$perf_cs_list $perf_cs_rate"
        cpu_migr_list="$cpu_migr_list $migr_rate"
        stime_list="$stime_list $stime_pct"
        utime_list="$utime_list $utime_pct"
        cycles_list="$cycles_list $cyc"
        instr_list="$instr_list $ins"

        echo "$pause_count,$run_idx,$qps,$vol_rate,$nonvol_rate,$perf_cs_rate,$migr_rate,$st_delta,$ut_delta" \
            >> "$RESULT_DIR/raw.csv"
    done

    mean_qps=$(compute_mean $qps_list)
    mean_vol=$(compute_mean_int $vol_cs_list)
    mean_nonvol=$(compute_mean_int $nonvol_cs_list)
    mean_perf_cs=$(compute_mean_int $perf_cs_list)
    mean_migr=$(compute_mean_int $cpu_migr_list)
    mean_stime=$(compute_mean $stime_list)
    mean_utime=$(compute_mean $utime_list)
    # mean IPC from accumulated cycles/instructions
    total_cyc=$(echo "$cycles_list" | tr ' ' '\n' | awk 'NF{s+=$1} END{print s}')
    total_ins=$(echo "$instr_list"  | tr ' ' '\n' | awk 'NF{s+=$1} END{print s}')
    mean_ipc=$(awk "BEGIN { if ($total_cyc>0) printf \"%.3f\", $total_ins/$total_cyc; else print \"0.000\" }")

    printf "    MEAN: QPS=%.0f  vol_cs/s=%s  nonvol_cs/s=%s  perf_cs/s=%s  stime_pct=%s%%  utime_pct=%s%%  IPC=%s\n" \
        "$mean_qps" "$mean_vol" "$mean_nonvol" "$mean_perf_cs" "$mean_stime" "$mean_utime" "$mean_ipc"

    echo "| $pause_count | $mean_qps | $mean_vol | $mean_nonvol | $mean_perf_cs | $mean_migr | ${mean_stime}% | ${mean_utime}% | $mean_ipc | $RUNS |" \
        >> "$RESULT_DIR/summary.md"

    cleanup; sleep 1
done

echo ""
echo "============================================================"
echo " SUMMARY"
echo "============================================================"
cat "$RESULT_DIR/summary.md"
echo ""
echo "Results: $RESULT_DIR"
