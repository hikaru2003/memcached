#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   bash experiment/run_approach_a.sh
#
# Description:
#   Approach A: MC_THREADS を 2/4/8 に変えながら N を固定して
#   handoff latency と demand_rfo の両方を計測する。
#   「スレッド増加 → RFO増加 → handoff latency増加」の因果を確認するための実験。
#
#   各スレッド数について handoff sweep + cache_miss sweep を順番に実行する。
#   終了後に全結果ディレクトリをまとめた approach_a_summary.md を生成する。
#
# Parameters (env vars):
#   PAUSE_PER_ROUND_VALUES - N sweep 値 (default: "0 25 50 100 200")
#   WARMUP_SEC             - warmup 秒数 (default: 60)
#   DURATION               - 計測秒数/run (default: 30)
#   RUNS                   - 各 N のラン数 (default: 3)
#   SPIN_ROUNDS            - trylock 試行回数（固定）(default: 30)
#
# Output:
#   experiment/results/handoff_YYYYMMDD_HHMMSS/    — MC_THREADS=2, 4, 8 の各ディレクトリ
#   experiment/results/cache_miss_YYYYMMDD_HHMMSS/ — MC_THREADS=2, 4, 8 の各ディレクトリ
#   experiment/results/approach_a_YYYYMMDD_HHMMSS/approach_a_summary.md
#
# Prerequisites:
#   - setup_perf_env.sh 適用済み（SMT off, performance governor, turbo off）
#   - ./memcached_handoff_debug, ./memcached, ./memcached_master
#   - ../mutilate/mutilate_p999

set -uo pipefail

PAUSE_PER_ROUND_VALUES="${PAUSE_PER_ROUND_VALUES:-0 25 50 100 200}"
WARMUP_SEC="${WARMUP_SEC:-60}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-3}"
SPIN_ROUNDS="${SPIN_ROUNDS:-30}"

# 所要時間推定
n_vals=$(echo "$PAUSE_PER_ROUND_VALUES" | wc -w)
per_handoff=$(( n_vals * (WARMUP_SEC + DURATION * RUNS) ))
per_cache=$(( (n_vals + 1) * (WARMUP_SEC + DURATION * RUNS) ))  # +1 は master
total_sec=$(( 3 * (per_handoff + per_cache) ))
total_min=$(( total_sec / 60 ))

RUN_DATE=$(date '+%Y%m%d_%H%M%S')
SUMMARY_DIR="experiment/results/approach_a_${RUN_DATE}"
mkdir -p "$SUMMARY_DIR"
SUMMARY_FILE="$SUMMARY_DIR/approach_a_summary.md"

echo "============================================================"
echo " Approach A: MC_THREADS variation experiment"
echo "============================================================"
echo " N values   : $PAUSE_PER_ROUND_VALUES"
echo " warmup     : ${WARMUP_SEC}s  duration: ${DURATION}s  runs: $RUNS"
echo " SPIN_ROUNDS: $SPIN_ROUNDS"
echo " est_time   : ~${total_min} min"
echo " summary    : $SUMMARY_FILE"
echo "============================================================"
echo ""

# スレッド数ごとの CPU affinity 設定
# MC_THREADS: MC_CPUS : WL_CPUS
# 2:          0-1      : 4-7
# 4:          0-3      : 4-7
# 8:          0-7      : 8-11
THREAD_COUNTS="2 4 8"

HANDOFF_DIRS=()
CACHE_DIRS=()

find_newest_dir() {
    local pattern=$1
    local ts=$2
    # ts 以降に作成された pattern に一致する最新ディレクトリを返す
    local d
    d=$(find experiment/results -maxdepth 1 -name "${pattern}_*" -newer "$SUMMARY_DIR" \
        -type d 2>/dev/null | sort | tail -1)
    echo "$d"
}

run_sweep() {
    local label=$1; shift
    # ラベルを先頭行に出力してから実際のスクリプトを実行
    echo ""
    echo "------------------------------------------------------------"
    echo " $label"
    echo "------------------------------------------------------------"
    env "$@"
}

for t in $THREAD_COUNTS; do
    case "$t" in
        2) mc_cpus="0-1"; wl_cpus="4-7" ;;
        4) mc_cpus="0-3"; wl_cpus="4-7" ;;
        8) mc_cpus="0-7"; wl_cpus="8-11" ;;
    esac

    echo "============================================================"
    echo " [MC_THREADS=$t]  MC_CPUS=$mc_cpus  WL_CPUS=$wl_cpus"
    echo "============================================================"

    # ---- handoff sweep ----
    echo ""
    echo ">>> [T=$t] handoff sweep"
    MC_THREADS="$t" MUT_THREADS=4 MC_CPUS="$mc_cpus" WL_CPUS="$wl_cpus" \
    PAUSE_PER_ROUND_VALUES="$PAUSE_PER_ROUND_VALUES" \
    WARMUP_SEC="$WARMUP_SEC" DURATION="$DURATION" RUNS="$RUNS" \
    SPIN_ROUNDS="$SPIN_ROUNDS" \
        bash experiment/run_handoff_sweep.sh

    hdir=$(find experiment/results -maxdepth 1 -name "handoff_*" -newer "$SUMMARY_DIR" \
               -type d 2>/dev/null | sort | tail -1)
    HANDOFF_DIRS+=("T${t}:${hdir}")
    echo ">>> [T=$t] handoff 完了: $hdir"

    # handoff 統計を抽出
    if [ -n "$hdir" ] && [ -d "$hdir" ]; then
        echo "    extract_handoff_stats.py 実行中..."
        python3 experiment/extract_handoff_stats.py --dir "$hdir" \
            && echo "    handoff_summary.csv 生成完了" \
            || echo "[WARN] extract_handoff_stats.py 失敗"
    fi

    echo ""

    # ---- cache_miss sweep ----
    echo ">>> [T=$t] cache_miss sweep"
    MC_THREADS="$t" MUT_THREADS=4 MC_CPUS="$mc_cpus" WL_CPUS="$wl_cpus" \
    PAUSE_PER_ROUND_VALUES="$PAUSE_PER_ROUND_VALUES" \
    WARMUP_SEC="$WARMUP_SEC" DURATION="$DURATION" RUNS="$RUNS" \
    SPIN_ROUNDS="$SPIN_ROUNDS" \
        bash experiment/run_cache_miss_sweep.sh

    cdir=$(find experiment/results -maxdepth 1 -name "cache_miss_*" -newer "$SUMMARY_DIR" \
               -type d 2>/dev/null | sort | tail -1)
    CACHE_DIRS+=("T${t}:${cdir}")
    echo ">>> [T=$t] cache_miss 完了: $cdir"
    echo ""
done

# ---- approach_a_summary.md を生成 ----
{
    echo "# Approach A 実験まとめ"
    echo ""
    echo "- 実行日時: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- N values: $PAUSE_PER_ROUND_VALUES"
    echo "- warmup: ${WARMUP_SEC}s / duration: ${DURATION}s / runs: $RUNS"
    echo "- spin_rounds: $SPIN_ROUNDS"
    echo "- 所要時間推定: ~${total_min} min"
    echo ""
    echo "## 目的"
    echo ""
    echo "N を固定してスレッド数を変化させ、「スレッド増加 → RFO増加 → handoff latency増加」の因果を確認する。"
    echo ""
    echo "| MC_THREADS | MC_CPUS | WL_CPUS |"
    echo "|---|---|---|"
    echo "| 2 | 0-1 | 4-7 |"
    echo "| 4 | 0-3 | 4-7 |"
    echo "| 8 | 0-7 | 8-11 |"
    echo ""
    echo "## 結果ディレクトリ"
    echo ""
    echo "### handoff sweep"
    for entry in "${HANDOFF_DIRS[@]}"; do
        t="${entry%%:*}"
        d="${entry#*:}"
        echo "- ${t}: \`${d}\`"
        if [ -f "${d}/handoff_summary.csv" ]; then
            echo "  - handoff_summary.csv: **あり**"
            # ヘッダー行を除いた最初の数行を表示
            echo "  \`\`\`"
            head -4 "${d}/handoff_summary.csv" | sed 's/^/  /'
            echo "  \`\`\`"
        else
            echo "  - handoff_summary.csv: なし（\`python3 experiment/extract_handoff_stats.py --dir ${d}\` 要実行）"
        fi
    done
    echo ""
    echo "### cache_miss sweep"
    for entry in "${CACHE_DIRS[@]}"; do
        t="${entry%%:*}"
        d="${entry#*:}"
        echo "- ${t}: \`${d}\`"
        if [ -f "${d}/summary.csv" ]; then
            echo "  - summary.csv: **あり**"
            echo "  \`\`\`"
            head -4 "${d}/summary.csv" | sed 's/^/  /'
            echo "  \`\`\`"
        else
            echo "  - summary.csv: なし"
        fi
    done
    echo ""
    echo "## push コマンド"
    echo ""
    echo "\`\`\`bash"
    echo "cd ~/Application/memcached"
    echo "EXPERIMENT_TYPE=handoff bash experiment/push_results.sh"
    echo "EXPERIMENT_TYPE=cache_miss bash experiment/push_results.sh"
    echo "\`\`\`"
    echo ""
    echo "## 期待する結果"
    echo ""
    echo "固定 N（例: N=50）でスレッド数を増やすと:"
    echo ""
    echo "| MC_THREADS | demand_rfo/req | handoff p99 |"
    echo "|---|---|---|"
    echo "| 2 | 低 | 短 |"
    echo "| 4 | 中 | 中 |"
    echo "| 8 | 高 | 長 |"
    echo ""
    echo "両者が同方向に増加すれば「RFO増加 → handoff latency増加」の相関が確認できる。"
    echo ""
    echo "---"
    echo "生成: $(date '+%Y-%m-%d %H:%M:%S')"
} > "$SUMMARY_FILE"

echo "============================================================"
echo " Approach A 完了"
echo " サマリー: $SUMMARY_FILE"
echo "============================================================"
echo ""
echo "次のステップ:"
echo "  push: EXPERIMENT_TYPE=handoff bash experiment/push_results.sh"
echo "        EXPERIMENT_TYPE=cache_miss bash experiment/push_results.sh"
echo ""
echo "  グラフ: python3 experiment/plot_handoff_comparison.py"
echo "          python3 experiment/plot_cache_miss_comparison.py"
