#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   bash experiment/run_utdelay_sweep_thread_stats.sh
#
# Description:
#   per-thread リクエスト数分布の計測スクリプト。
#   スタベーション仮説（N大 → 特定スレッドがロック独占）の検証用。
#   各 N 値につき、ラン毎に "stats threads" で per-thread 処理数を取得し CSV に保存する。
#   "stats reset" を warmup 後・各ラン後に発行することで、ラン単位のカウントを取得する。
#
# Parameters (env vars):
#   MEMCACHED_BIN          - utdelay バイナリ                (default: ./memcached)
#   MEMCACHED_MASTER_BIN   - master バイナリ（スピンなし）    (default: ./memcached_master)
#   MUTILATE_BIN           - mutilate バイナリ               (default: ../mutilate/mutilate_p999)
#   MC_THREADS             - memcached ワーカースレッド数     (default: 4)
#   MUT_THREADS            - mutilate クライアントスレッド数  (default: 4)
#   MUT_CONNS              - mutilate コネクション/スレッド   (default: 1)
#   DEPTH                  - mutilate pipeline depth (-d)     (default: 32)
#   RECORDS                - key range (-r)                   (default: 1)
#   UPDATE_RATIO           - SET 割合 (-u)                    (default: 0.5)
#   WARMUP_SEC             - warmup 秒数                     (default: 150)
#   DURATION               - 計測秒数                        (default: 60)
#   RUNS                   - 各 N のラン数                    (default: 3)
#   SPIN_ROUNDS            - trylock 試行回数（固定）          (default: 30)
#   PAUSE_PER_ROUND_VALUES - N sweep 値                      (default: 0 4 10 30 100 200)
#   PORT                   - memcached ポート                (default: 11222)
#   MC_CPUS                - memcached CPU affinity          (default: 0-3)
#   WL_CPUS                - mutilate CPU affinity           (default: 4-7)
#
# Output:
#   experiment/results/utdelay_thread_stats_YYYYMMDD_HHMMSS/
#     run_info.md    - 実験パラメータ
#     summary.md     - N別 QPS / per-thread 分布（max/min 比）統計テーブル
#     raw.csv        - 全ランの生データ（thread_N_reqs カラム含む）
#     raw/           - mutilate ログ
#
# Prerequisites:
#   - ./memcached: experiment/mysql-like-utdelay ブランチのビルド（stats threads 対応済み）
#   - ./memcached_master: master ブランチのビルド
#   - ../mutilate/mutilate_p999: p999 対応 mutilate バイナリ（なければ mutilate でも可）
#   - nc コマンド（netcat）

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
RUNS="${RUNS:-3}"
SPIN_ROUNDS="${SPIN_ROUNDS:-30}"
PAUSE_PER_ROUND_VALUES="${PAUSE_PER_ROUND_VALUES:-0 4 10 30 100 200}"
PORT="${PORT:-11222}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"

# mutilate_p999 がなければ通常の mutilate にフォールバック
if [ ! -x "$MUTILATE_BIN" ]; then
    MUTILATE_BIN="${MUTILATE_BIN%_p999}"
fi

check_perf_env() {
    local errors=0
    local smt_val
    smt_val=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo "N/A")
    if [ "$smt_val" = "N/A" ]; then
        echo "[WARN] SMT status unknown"
    elif [ "$smt_val" != "0" ]; then
        echo "[ERROR] SMT is ON"; errors=$(( errors + 1 ))
    fi
    local gov
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    if [ "$gov" = "N/A" ]; then
        echo "[WARN] governor status unknown"
    elif [ "$gov" != "performance" ]; then
        echo "[ERROR] governor=$gov (expected: performance)"; errors=$(( errors + 1 ))
    fi
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        local no_turbo
        no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
        if [ "$no_turbo" != "1" ]; then
            echo "[ERROR] Turbo Boost is ON"; errors=$(( errors + 1 ))
        fi
    elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        local boost_val
        boost_val=$(cat /sys/devices/system/cpu/cpufreq/boost)
        if [ "$boost_val" != "0" ]; then
            echo "[ERROR] Turbo Boost is ON"; errors=$(( errors + 1 ))
        fi
    else
        echo "[WARN] Turbo Boost status unknown"
    fi
    if [ "$errors" -gt 0 ]; then
        echo "[ERROR] $errors check(s) failed. Fix: sudo bash experiment/setup_perf_env.sh"
        exit 1
    fi
    echo "[OK] CPU env: SMT=off, governor=performance, turbo=off"
}
check_perf_env

# nc でmemcached にコマンドを送信して結果を返す
mc_cmd() {
    printf "%s\r\n" "$1" | timeout 2 nc 127.0.0.1 "$PORT" 2>/dev/null | tr -d '\r' || true
}

# per-thread リクエスト数を取得（スペース区切り: thread_0 thread_1 ... thread_{N-1}）
get_thread_stats() {
    local output
    output=$(mc_cmd "stats threads")
    local counts=""
    for i in $(seq 0 $(( MC_THREADS - 1 ))); do
        local c
        c=$(echo "$output" | awk "/thread_${i}_requests/{print \$3}")
        counts="$counts ${c:-0}"
    done
    echo $counts
}

RUN_DATE=$(date '+%Y%m%d_%H%M%S')
RESULT_DIR="experiment/results/utdelay_thread_stats_${RUN_DATE}"
mkdir -p "$RESULT_DIR/raw"

n_vals=$(echo "$PAUSE_PER_ROUND_VALUES" | wc -w)
est_sec=$(( (n_vals + 1) * (WARMUP_SEC + DURATION * RUNS) ))
est_min=$(( est_sec / 60 ))

# CSV ヘッダ（thread カラムを動的生成）
thread_cols=""
for i in $(seq 0 $(( MC_THREADS - 1 ))); do thread_cols="${thread_cols},thread_${i}_reqs"; done

{
    echo "# Run info (utdelay thread stats sweep)"
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "- utdelay_bin: $MEMCACHED_BIN"
    echo "- master_bin:  $MEMCACHED_MASTER_BIN"
    echo "- mutilate_bin: $MUTILATE_BIN"
    echo "- mc_threads: $MC_THREADS (cpus: $MC_CPUS)"
    echo "- mut: -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- spin_rounds: $SPIN_ROUNDS (fixed)"
    echo "- pause_per_round values: $PAUSE_PER_ROUND_VALUES"
    echo "- est_time: ~${est_min} min"
} > "$RESULT_DIR/run_info.md"

{
    echo "# utdelay thread stats sweep"
    echo ""
    echo "| label | N | mean_QPS | r_p99_avg | r_p999_avg | max/min_ratio | dominant_thread | n |"
    echo "|---|---|---|---|---|---|---|---|"
} > "$RESULT_DIR/summary.md"

echo "label,pause_per_round,spin_rounds,total_pause_budget,run,QPS,r_avg_us,r_p99_us,r_p999_us${thread_cols}" \
    > "$RESULT_DIR/raw.csv"

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
            echo "[mc] PID=$MC_PID  bin=$(basename $bin)  ppr=$ppr"
            return 0
        fi
    done
    echo "[ERROR] memcached did not start on port $PORT" >&2; return 1
}

# mutilate 出力カラム（mutilate_p999: $9=99th $10=999th / 通常: $9=99th）
extract_qps()    { grep -E "^Total QPS" "$1" | awk '{print $4}'; }
extract_r_avg()  { grep -E "^read" "$1" | awk '{print $2}'; }
extract_r_p99()  { grep -E "^read" "$1" | awk '{print $9}'; }
extract_r_p999() { grep -E "^read" "$1" | awk '{print $10}'; }  # p999バイナリのみ有効

compute_mean() {
    echo "$@" | tr ' ' '\n' | awk 'NR>0{s+=$1}END{printf "%.1f",s/NR}'
}

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

run_one_config() {
    local label=$1 bin=$2 ppr=$3
    local total_budget
    if [ "$ppr" = "master" ]; then total_budget=0
    else total_budget=$(( SPIN_ROUNDS * ppr )); fi

    echo ""
    echo "=============================="
    echo " $label  (total_pause_budget=$total_budget)"
    echo "=============================="

    start_memcached "$bin" "$ppr"

    echo "    warmup ${WARMUP_SEC}s ..."
    taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
        -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
        -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$WARMUP_SEC" \
        > /dev/null 2>&1 || true

    # warmup 後にカウンタをリセットして計測開始
    mc_cmd "stats reset" > /dev/null

    local qps_list="" r_avg_list="" r_p99_list="" r_p999_list=""
    local all_thread_counts=()  # 全ランの per-thread 合計（summary 用）
    for i in $(seq 0 $(( MC_THREADS - 1 ))); do all_thread_counts[$i]=0; done

    for run_idx in $(seq 1 "$RUNS"); do
        local logfile="$RESULT_DIR/raw/run_${label}_${run_idx}.log"
        taskset -c "$WL_CPUS" "$MUTILATE_BIN" \
            -s "127.0.0.1:$PORT" -r "$RECORDS" -u "$UPDATE_RATIO" \
            -T "$MUT_THREADS" -c "$MUT_CONNS" -d "$DEPTH" -t "$DURATION" \
            > "$logfile" 2>&1

        # per-thread リクエスト数を取得
        local thread_counts
        thread_counts=$(get_thread_stats)

        # カウンタをリセット（次のランのため）
        mc_cmd "stats reset" > /dev/null

        local qps r_avg r_p99 r_p999
        qps=$(extract_qps  "$logfile")
        r_avg=$(extract_r_avg "$logfile")
        r_p99=$(extract_r_p99 "$logfile")
        r_p999=$(extract_r_p999 "$logfile")

        # per-thread を配列に展開
        local t_arr=( $thread_counts )

        # CSV 行の per-thread 部分を構築
        local thread_csv=""
        local t_max=0 t_min=999999999999 t_dominant=0
        for i in $(seq 0 $(( MC_THREADS - 1 ))); do
            local t_val="${t_arr[$i]:-0}"
            thread_csv="${thread_csv},${t_val}"
            all_thread_counts[$i]=$(( all_thread_counts[$i] + t_val ))
            if [ "$t_val" -gt "$t_max" ] 2>/dev/null; then t_max=$t_val; t_dominant=$i; fi
            if [ "$t_val" -lt "$t_min" ] 2>/dev/null && [ "$t_val" -gt 0 ]; then t_min=$t_val; fi
        done

        local ratio="N/A"
        if [ "$t_min" -gt 0 ] 2>/dev/null; then
            ratio=$(awk "BEGIN{printf \"%.2f\", $t_max / $t_min}")
        fi

        printf "    run %d/%d: QPS=%.0f  r_p99=%s  r_p999=%s  threads=[%s]  max/min=%s\n" \
            "$run_idx" "$RUNS" "$qps" "$r_p99" "$r_p999" \
            "$(echo $thread_counts | tr ' ' ',')" "$ratio"

        qps_list="$qps_list $qps"
        r_avg_list="$r_avg_list $r_avg"
        r_p99_list="$r_p99_list $r_p99"
        r_p999_list="$r_p999_list $r_p999"

        echo "${label},${ppr},${SPIN_ROUNDS},${total_budget},${run_idx},${qps},${r_avg},${r_p99},${r_p999}${thread_csv}" \
            >> "$RESULT_DIR/raw.csv"
    done

    # サマリ統計
    local mean_qps med_qps sd_qps cv_qps
    read mean_qps med_qps sd_qps cv_qps <<< "$(compute_stats $qps_list)"
    local mean_r_p99 mean_r_p999
    mean_r_p99=$(compute_mean $r_p99_list)
    mean_r_p999=$(compute_mean $r_p999_list)

    # 全ラン合計での max/min 比とドミナントスレッド
    local sum_max=0 sum_min=999999999999 sum_dominant=0
    for i in $(seq 0 $(( MC_THREADS - 1 ))); do
        local v=${all_thread_counts[$i]}
        if [ "$v" -gt "$sum_max" ] 2>/dev/null; then sum_max=$v; sum_dominant=$i; fi
        if [ "$v" -lt "$sum_min" ] 2>/dev/null && [ "$v" -gt 0 ]; then sum_min=$v; fi
    done
    local sum_ratio="N/A"
    if [ "$sum_min" -gt 0 ] 2>/dev/null; then
        sum_ratio=$(awk "BEGIN{printf \"%.2f\", $sum_max / $sum_min}")
    fi

    printf "    STATS: QPS_mean=%.0f  r_p99=%s  r_p999=%s  max/min=%s (dominant=thread_%d)\n" \
        "$mean_qps" "$mean_r_p99" "$mean_r_p999" "$sum_ratio" "$sum_dominant"

    echo "| $label | $ppr | $mean_qps | $mean_r_p99 | $mean_r_p999 | $sum_ratio | thread_${sum_dominant} | $RUNS |" \
        >> "$RESULT_DIR/summary.md"

    cleanup; sleep 1
}

echo "============================================================"
echo " memcached utdelay thread stats sweep"
echo "============================================================"
echo " utdelay_bin : $MEMCACHED_BIN"
echo " master_bin  : $MEMCACHED_MASTER_BIN"
echo " mutilate    : $MUTILATE_BIN"
echo " mc_threads  : $MC_THREADS  cpus: $MC_CPUS"
echo " mut         : -T $MUT_THREADS -c $MUT_CONNS -d $DEPTH -r $RECORDS -u $UPDATE_RATIO"
echo " warmup      : ${WARMUP_SEC}s  measure: ${DURATION}s  runs: $RUNS"
echo " SPIN_ROUNDS : $SPIN_ROUNDS (fixed)"
echo " N values    : $PAUSE_PER_ROUND_VALUES"
echo " est_time    : ~${est_min} min"
echo " results     : $RESULT_DIR"
echo "============================================================"

if [ -x "$MEMCACHED_MASTER_BIN" ]; then
    run_one_config "master" "$MEMCACHED_MASTER_BIN" "master"
else
    echo "[WARN] master binary not found: $MEMCACHED_MASTER_BIN  skipping baseline"
fi

for ppr in $PAUSE_PER_ROUND_VALUES; do
    run_one_config "N${ppr}" "$MEMCACHED_BIN" "$ppr"
done

echo ""
echo "============================================================"
echo " FINAL SUMMARY"
echo "============================================================"
cat "$RESULT_DIR/summary.md"
echo ""
echo "Results: $RESULT_DIR"
