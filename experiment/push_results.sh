#!/bin/bash
# Usage:
#   # 実験後、memcachedリポジトリのルートで実行:
#   cd ~/Application/memcached
#   bash experiment/push_results.sh
#
# Description:
#   CloudLab サーバ上での実験結果を GitHub にプッシュする。
#   experiment/results/<arch>-utdelay-YYYYMMDD ブランチを作成し、
#   results ディレクトリのみをコミット・プッシュする。
#
# Parameters (env vars):
#   ARCH_NAME   - アーキテクチャ名 (default: 自動検出)
#   RESULT_DIR  - 結果ディレクトリ (default: experiment/results)
#   REMOTE      - push 先リモート  (default: myfork)
#   BASE_BRANCH - 分岐元ブランチ   (default: experiment/mysql-like-utdelay)
#
# Output:
#   origin/experiment/results/<arch>-utdelay-YYYYMMDD ブランチ
#
# Prerequisites:
#   - GitHub への push 権限（SSH key or HTTPS token 設定済み）
#   - setup_cloudlab.sh 実行済み（memcached がビルド済み）

set -uo pipefail

RESULT_DIR="${RESULT_DIR:-experiment/results}"
REMOTE="${REMOTE:-myfork}"
BASE_BRANCH="${BASE_BRANCH:-experiment/mysql-like-utdelay}"

# アーキテクチャ名の自動検出
if [ -z "${ARCH_NAME:-}" ]; then
    cpu_model=$(grep "^model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')
    if echo "$cpu_model" | grep -qiE "broadwell|E5.*v4"; then
        ARCH_NAME="broadwell"
    elif echo "$cpu_model" | grep -qiE "ivy|E5.*v2|E3.*v2"; then
        ARCH_NAME="ivybridge"
    elif echo "$cpu_model" | grep -qiE "emerald|sapphire"; then
        ARCH_NAME="emeraldrapids"
    elif echo "$cpu_model" | grep -qiE "ice lake|icelake"; then
        ARCH_NAME="icelake"
    elif echo "$cpu_model" | grep -qiE "skylake|Silver 4[01]|Gold 5[12]|Gold 6[12]|Platinum 8[12]"; then
        ARCH_NAME="skylake"
    else
        ARCH_NAME="unknown"
        echo "[WARN] Architecture not detected. CPU: $cpu_model"
        echo "  Set ARCH_NAME env var to override (e.g., ARCH_NAME=skylake)"
        read -rp "  Continue with ARCH_NAME=unknown? [y/N] " ans
        [ "$ans" = "y" ] || exit 1
    fi
fi

DATE_TAG=$(date '+%Y%m%d')
BRANCH="experiment/results/${ARCH_NAME}-utdelay-${DATE_TAG}"

echo "============================================================"
echo " push results: $BRANCH"
echo "============================================================"
echo " arch       : $ARCH_NAME"
echo " result_dir : $RESULT_DIR"
echo " remote     : $REMOTE"
echo " branch     : $BRANCH"
echo "============================================================"

# リモートが設定されているか確認
if ! git remote | grep -q "^${REMOTE}$"; then
    echo "[ERROR] Remote '$REMOTE' not configured." >&2
    echo "  Run: git remote add myfork git@github.com:hikaru2003/memcached.git" >&2
    exit 1
fi

# 現在のブランチを記録
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# ブランチ作成（BASE_BRANCHから分岐）
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    echo "  Branch $BRANCH already exists. Checking out."
    git checkout "$BRANCH"
else
    echo "  Creating branch $BRANCH from $BASE_BRANCH ..."
    git fetch "$REMOTE" "$BASE_BRANCH" 2>/dev/null || true
    git checkout -b "$BRANCH" "$BASE_BRANCH" 2>/dev/null || \
        git checkout -b "$BRANCH" "origin/$BASE_BRANCH" 2>/dev/null || \
        git checkout -b "$BRANCH"
fi

# 結果ファイルをステージ
if [ ! -d "$RESULT_DIR" ]; then
    echo "[ERROR] Result directory not found: $RESULT_DIR" >&2
    exit 1
fi

result_count=$(find "$RESULT_DIR" -name "*.csv" -o -name "summary.md" | wc -l)
if [ "$result_count" -eq 0 ]; then
    echo "[WARN] No result files (*.csv, summary.md) found in $RESULT_DIR" >&2
    read -rp "  Continue anyway? [y/N] " ans
    [ "$ans" = "y" ] || exit 1
fi

git add "$RESULT_DIR/"

if git diff --cached --quiet; then
    echo "[INFO] Nothing to commit. Results already up to date."
else
    commit_msg="results: utdelay pause_per_round sweep on ${ARCH_NAME} ($(date '+%Y-%m-%d'))"
    git commit -m "$commit_msg"
    echo "  Committed: $commit_msg"
fi

# push
echo "  Pushing to $REMOTE/$BRANCH ..."
git push "$REMOTE" "${BRANCH}:${BRANCH}"

echo ""
echo "Pushed: $REMOTE/$BRANCH"
echo ""
echo "このサーバでの収集コマンド（光のマシンで実行）:"
echo "  git fetch myfork && bash experiment/collect_results.sh"

# 元のブランチに戻る
git checkout "$CURRENT_BRANCH"
