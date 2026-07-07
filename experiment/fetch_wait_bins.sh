#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   bash experiment/fetch_wait_bins.sh <node_host> [arch_name]
#
#   例:
#   bash experiment/fetch_wait_bins.sh hp142.utah.cloudlab.us broadwell
#   bash experiment/fetch_wait_bins.sh clnode018.clemson.cloudlab.us ivybridge
#
# Description:
#   CloudLab サーバ上の wait_dist_* ディレクトリから .bin ファイルを
#   ann サーバの experiment/results/<arch>/ に rsync で取得する。
#   wait_summary.csv / run_info.md は collect_results.sh (git) で取得済みの想定。
#
# Parameters:
#   $1  - CloudLab ノードのホスト名 (必須)
#   $2  - アーキテクチャ名 (省略時は自動推定)
#
# Output:
#   experiment/results/<arch>/wait_dist_YYYYMMDD_HHMMSS/N<n>/wait_samples_thread*.bin
#
# Prerequisites:
#   - ssh -A でログイン済み（SSH agent forwarding）
#   - CloudLab ノード上で wait distribution 実験が完了していること

set -euo pipefail

NODE_HOST="${1:-}"
ARCH_NAME="${2:-}"

if [ -z "$NODE_HOST" ]; then
    echo "Usage: bash experiment/fetch_wait_bins.sh <node_host> [arch_name]" >&2
    echo "  例: bash experiment/fetch_wait_bins.sh hp142.utah.cloudlab.us broadwell" >&2
    exit 1
fi

REMOTE_USER="Morisaki"
REMOTE_RESULT_DIR="/users/Morisaki/memcached/experiment/results"
LOCAL_RESULT_BASE="$(cd "$(dirname "$0")/.." && pwd)/experiment/results"

# アーキテクチャ名の推定（未指定時）
if [ -z "$ARCH_NAME" ]; then
    cpu_model=$(ssh "${REMOTE_USER}@${NODE_HOST}" \
        "grep '^model name' /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//'")
    echo "  Remote CPU: $cpu_model"
    if echo "$cpu_model" | grep -qiE "E5-2[0-9]+.*v4|E7-.*v4|broadwell"; then
        ARCH_NAME="broadwell"
    elif echo "$cpu_model" | grep -qiE "E5-2[0-9]+.*v2|E7-.*v2|E3-.*v2"; then
        ARCH_NAME="ivybridge"
    elif echo "$cpu_model" | grep -qiE "6554|6548|6538|emerald"; then
        ARCH_NAME="emeraldrapids"
    elif echo "$cpu_model" | grep -qiE "6338|6348|6354|ice lake|icelake"; then
        ARCH_NAME="icelake"
    elif echo "$cpu_model" | grep -qiE "Silver 4114|Silver 41[0-9]{2}|Gold 5[12][0-9]{2}|skylake"; then
        ARCH_NAME="skylake"
    else
        echo "[ERROR] Architecture not detected. Specify manually as \$2." >&2
        echo "  CPU: $cpu_model" >&2
        exit 1
    fi
    echo "  Detected arch: $ARCH_NAME"
fi

LOCAL_DEST="$LOCAL_RESULT_BASE/$ARCH_NAME"
mkdir -p "$LOCAL_DEST"

echo "============================================================"
echo " fetch_wait_bins.sh"
echo "============================================================"
echo " node   : ${REMOTE_USER}@${NODE_HOST}"
echo " arch   : $ARCH_NAME"
echo " remote : $REMOTE_RESULT_DIR/wait_dist_*/"
echo " local  : $LOCAL_DEST/"
echo "============================================================"

# wait_dist_* ディレクトリ一覧を取得
wait_dirs=$(ssh "${REMOTE_USER}@${NODE_HOST}" \
    "ls -d ${REMOTE_RESULT_DIR}/wait_dist_*/ 2>/dev/null || true")

if [ -z "$wait_dirs" ]; then
    echo "[WARN] No wait_dist_* directories found on $NODE_HOST"
    exit 0
fi

echo " Found directories:"
echo "$wait_dirs" | sed 's/^/   /'
echo ""

# .bin ファイルのみ rsync
for remote_dir in $wait_dirs; do
    dir_name=$(basename "$remote_dir")
    local_dir="$LOCAL_DEST/$dir_name"
    mkdir -p "$local_dir"
    echo "  Syncing $dir_name ..."
    rsync -avz --include="*/" --include="*.bin" --exclude="*" \
        "${REMOTE_USER}@${NODE_HOST}:${remote_dir}" \
        "$local_dir/../"
done

echo ""
echo "============================================================"
echo " Done. .bin files saved to:"
echo "   $LOCAL_DEST/"
echo "============================================================"
