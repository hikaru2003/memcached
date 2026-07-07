#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   bash experiment/push_results.sh                       # utdelay sweep 結果
#   EXPERIMENT_TYPE=wait bash experiment/push_results.sh  # wait distribution 結果
#
# Description:
#   CloudLab サーバ上での実験結果を GitHub にプッシュする。
#   実験タイプに応じてブランチを作成し、結果ファイルのみをコミット・プッシュする。
#   .bin ファイル（大容量）は除外し、CSV・md のみを push する。
#
# Parameters (env vars):
#   EXPERIMENT_TYPE - 実験タイプ: utdelay | wait  (default: utdelay)
#   ARCH_NAME       - アーキテクチャ名             (default: 自動検出)
#   RESULT_DIR      - 結果ディレクトリ             (default: experiment/results)
#   REMOTE          - push 先リモート              (default: myfork)
#
# Output:
#   origin/experiment/results/<arch>-utdelay-YYYYMMDD  : utdelay sweep 結果
#   origin/experiment/results/<arch>-wait-YYYYMMDD     : wait distribution 結果
#
# Prerequisites:
#   - GitHub への push 権限（ssh -A でのエージェント転送 or HTTPS token）
#   - utdelay: run_utdelay_sweep_p999.sh 実行済み
#   - wait   : run_wait_distribution.sh + extract_wait_stats.py 実行済み

set -uo pipefail

EXPERIMENT_TYPE="${EXPERIMENT_TYPE:-utdelay}"
RESULT_DIR="${RESULT_DIR:-experiment/results}"
REMOTE="${REMOTE:-myfork}"

# --- アーキテクチャ名の自動検出 ---
if [ -z "${ARCH_NAME:-}" ]; then
    cpu_model=$(grep "^model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')
    if echo "$cpu_model" | grep -qiE "broadwell|E5.*v4"; then
        ARCH_NAME="broadwell"
    elif echo "$cpu_model" | grep -qiE "ivy|E5.*v2|E3.*v2"; then
        ARCH_NAME="ivybridge"
    elif echo "$cpu_model" | grep -qiE "6554|6548|6538|6530|55[0-9][0-9]|emerald"; then
        ARCH_NAME="emeraldrapids"
    elif echo "$cpu_model" | grep -qiE "6338|6348|6354|Silver 4[3-9][0-9]{2}|ice lake|icelake"; then
        ARCH_NAME="icelake"
    elif echo "$cpu_model" | grep -qiE "skylake|Silver 4[01]|Gold 5[12]|Gold 6[12]|Platinum 8[12]"; then
        ARCH_NAME="skylake"
    else
        ARCH_NAME="unknown"
        echo "[WARN] Architecture not detected. CPU: $cpu_model"
        echo "  Set ARCH_NAME env var to override (e.g., ARCH_NAME=broadwell)"
        read -rp "  Continue with ARCH_NAME=unknown? [y/N] " ans
        [ "$ans" = "y" ] || exit 1
    fi
fi

DATE_TAG=$(date '+%Y%m%d')
BRANCH="experiment/results/${ARCH_NAME}-${EXPERIMENT_TYPE}-${DATE_TAG}"

echo "============================================================"
echo " push results: $BRANCH"
echo "============================================================"
echo " type       : $EXPERIMENT_TYPE"
echo " arch       : $ARCH_NAME"
echo " result_dir : $RESULT_DIR"
echo " remote     : $REMOTE"
echo " branch     : $BRANCH"
echo "============================================================"

# リモート確認
if ! git remote | grep -q "^${REMOTE}$"; then
    echo "[ERROR] Remote '$REMOTE' not configured." >&2
    echo "  git remote add myfork git@github.com:hikaru2003/memcached.git" >&2
    exit 1
fi

# 結果ディレクトリ確認
if [ ! -d "$RESULT_DIR" ]; then
    echo "[ERROR] Result directory not found: $RESULT_DIR" >&2
    exit 1
fi

# push するファイルを収集（タイプ別）
stage_files() {
    if [ "$EXPERIMENT_TYPE" = "wait" ]; then
        # wait_dist_*/wait_summary.csv と run_info.md のみ（.bin は除外）
        local found=0
        while IFS= read -r -d '' f; do
            git add -f "$f"
            found=$((found + 1))
        done < <(find "$RESULT_DIR" -path "*/wait_dist_*" \
            \( -name "wait_summary.csv" -o -name "run_info.md" \) -print0)
        echo "  staged $found file(s) for wait experiment"
        if [ "$found" -eq 0 ]; then
            echo "[ERROR] wait_summary.csv not found. extract_wait_stats.py を先に実行してください。" >&2
            exit 1
        fi
    else
        # utdelay: raw.csv / summary.md / run_info.md / raw/*.log
        local found=0
        while IFS= read -r -d '' f; do
            git add -f "$f"
            found=$((found + 1))
        done < <(find "$RESULT_DIR" -path "*/utdelay_p999_*" \
            \( -name "raw.csv" -o -name "summary.md" -o -name "run_info.md" -o -name "*.log" \) -print0)
        echo "  staged $found file(s) for utdelay experiment"
        if [ "$found" -eq 0 ]; then
            echo "[WARN] No result files found in $RESULT_DIR" >&2
        fi
    fi
}

# 現在のブランチを記録
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# ブランチ作成
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    echo "  Branch $BRANCH already exists. Checking out."
    git checkout "$BRANCH"
else
    echo "  Creating branch $BRANCH ..."
    # BASE_BRANCH はタイプに応じて選択
    if [ "$EXPERIMENT_TYPE" = "wait" ]; then
        BASE="debug/wait-time"
    else
        BASE="experiment/mysql-like-utdelay"
    fi
    git checkout -b "$BRANCH" "$BASE" 2>/dev/null || \
        git checkout -b "$BRANCH" "origin/$BASE" 2>/dev/null || \
        git checkout -b "$BRANCH"
fi

stage_files

if git diff --cached --quiet; then
    echo "[INFO] Nothing to commit. Results already up to date."
else
    commit_msg="results: ${EXPERIMENT_TYPE} sweep on ${ARCH_NAME} ($(date '+%Y-%m-%d'))"
    git commit -m "$commit_msg"
    echo "  Committed: $commit_msg"
fi

echo "  Pushing to $REMOTE/$BRANCH ..."
git push "$REMOTE" "${BRANCH}:${BRANCH}"

echo ""
echo "Pushed: $REMOTE/$BRANCH"
echo ""
echo "ann サーバでの収集コマンド:"
echo "  git fetch myfork && bash experiment/collect_results.sh"

git checkout "$CURRENT_BRANCH"
