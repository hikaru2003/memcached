#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   git fetch myfork
#   bash experiment/collect_results.sh
#
# Description:
#   各 CloudLab サーバがプッシュした experiment/results/<arch>-utdelay-* ブランチから
#   結果ファイルを収集し、experiment/results/<arch>/ に配置する。
#   既存の結果は上書きしない（新しいサブディレクトリのみ追加）。
#
# Parameters (env vars):
#   REMOTE       - fetch 元リモート             (default: myfork)
#   RESULT_BASE  - ローカルの結果格納先         (default: experiment/results)
#   DRY_RUN      - "1" で実際にコピーしない     (default: "")
#
# Output:
#   experiment/results/<arch>/utdelay_sweep_*/   - 各アーキの実験結果
#
# Prerequisites:
#   - git fetch myfork を事前に実行済みであること

set -uo pipefail

REMOTE="${REMOTE:-myfork}"
RESULT_BASE="${RESULT_BASE:-experiment/results}"
DRY_RUN="${DRY_RUN:-}"

echo "============================================================"
echo " collect results from $REMOTE"
echo "============================================================"

# experiment/results/<arch>-utdelay-* ブランチを列挙
branches=$(git branch -r | grep "${REMOTE}/experiment/results/.*-utdelay-" | sed 's|.*'"${REMOTE}"'/||' | tr -d ' ')

if [ -z "$branches" ]; then
    echo "[INFO] No result branches found on $REMOTE."
    echo "  Expected pattern: experiment/results/<arch>-utdelay-YYYYMMDD"
    exit 0
fi

echo " Found branches:"
echo "$branches" | sed 's/^/   /'
echo ""

collected=0
for branch in $branches; do
    # arch名を抽出: experiment/results/<arch>-utdelay-YYYYMMDD → <arch>
    arch=$(echo "$branch" | sed 's|experiment/results/||' | sed 's/-utdelay-.*//')
    date_tag=$(echo "$branch" | grep -o '[0-9]\{8\}$' || echo "unknown")

    dest="$RESULT_BASE/${arch}"
    echo "--- $arch ($date_tag) ---"
    echo "  branch: $branch"
    echo "  dest  : $dest"

    if [ -n "$DRY_RUN" ]; then
        echo "  [DRY_RUN] Would extract to $dest"
        continue
    fi

    mkdir -p "$dest"

    # git archive でブランチの experiment/results/ 以下を展開
    git archive "${REMOTE}/${branch}" -- experiment/results/ 2>/dev/null | \
        tar -x --strip-components=2 -C "$dest" 2>/dev/null || {
        echo "  [WARN] Archive failed for $branch, trying alternative..." >&2
        # fallback: git show でファイルを直接取り出す
        git ls-tree -r --name-only "${REMOTE}/${branch}" -- experiment/results/ | \
        while read -r filepath; do
            relpath="${filepath#experiment/results/}"
            destfile="$dest/$relpath"
            mkdir -p "$(dirname "$destfile")"
            if [ ! -f "$destfile" ]; then
                git show "${REMOTE}/${branch}:${filepath}" > "$destfile"
                echo "  extracted: $relpath"
            else
                echo "  skip (exists): $relpath"
            fi
        done
    }

    echo "  Done."
    collected=$((collected + 1))
done

echo ""
echo "============================================================"
echo " Collected $collected architecture(s) -> $RESULT_BASE/"
echo "============================================================"
ls -la "$RESULT_BASE/" 2>/dev/null

if [ "$collected" -gt 0 ]; then
    echo ""
    echo "全アーキ比較グラフの生成:"
    echo "  python3 experiment/plot_arch_comparison.py"
fi
