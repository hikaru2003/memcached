#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   git fetch myfork
#   bash experiment/collect_results.sh
#
# Description:
#   各 CloudLab サーバがプッシュした experiment/results/<arch>-<type>-* ブランチから
#   結果ファイルを収集し、experiment/results/<arch>/ に配置する。
#   対応タイプ:
#     utdelay → experiment/results/<arch>/utdelay_sweep_*/  または utdelay_p999_*/
#     wait    → experiment/results/<arch>/wait_dist_*/
#
# Parameters (env vars):
#   REMOTE       - fetch 元リモート          (default: myfork)
#   RESULT_BASE  - ローカルの結果格納先      (default: experiment/results)
#   DRY_RUN      - "1" で実際にコピーしない  (default: "")
#
# Output:
#   experiment/results/<arch>/<type_dir>/
#
# Prerequisites:
#   git fetch myfork を事前に実行済みであること

set -uo pipefail

REMOTE="${REMOTE:-myfork}"
RESULT_BASE="${RESULT_BASE:-experiment/results}"
DRY_RUN="${DRY_RUN:-}"

echo "============================================================"
echo " collect results from $REMOTE"
echo "============================================================"

# experiment/results/<arch>-<type>-YYYYMMDD ブランチを列挙
branches=$(git branch -r \
    | grep "${REMOTE}/experiment/results/.*-[a-z]*-[0-9]\{8\}" \
    | sed "s|.*${REMOTE}/||" \
    | tr -d ' ')

if [ -z "$branches" ]; then
    echo "[INFO] No result branches found on $REMOTE."
    echo "  Expected pattern: experiment/results/<arch>-<type>-YYYYMMDD"
    exit 0
fi

echo " Found branches:"
echo "$branches" | sed 's/^/   /'
echo ""

collected=0
for branch in $branches; do
    # arch と type を抽出
    # experiment/results/<arch>-<type>-YYYYMMDD
    base=$(echo "$branch" | sed 's|experiment/results/||')
    date_tag=$(echo "$base" | grep -o '[0-9]\{8\}$' || echo "unknown")
    # <arch>-<type>-YYYYMMDD → <arch>-<type>
    arch_type=$(echo "$base" | sed 's/-[0-9]\{8\}$//')
    # <arch>-<type> → arch, type
    # type は最後の -区切り要素
    exp_type=$(echo "$arch_type" | rev | cut -d- -f1 | rev)
    arch=$(echo "$arch_type" | rev | cut -d- -f2- | rev)

    dest="$RESULT_BASE/${arch}"
    echo "--- $arch / $exp_type ($date_tag) ---"
    echo "  branch: $branch"
    echo "  dest  : $dest"

    if [ -n "$DRY_RUN" ]; then
        echo "  [DRY_RUN] Would extract to $dest"
        continue
    fi

    mkdir -p "$dest"

    # git archive でブランチの experiment/results/ 以下を展開
    # strip-components=2 で experiment/results/ プレフィクスを除去 → <arch>/ 配下に展開
    if git archive "${REMOTE}/${branch}" -- experiment/results/ 2>/dev/null \
        | tar -x --strip-components=2 -C "$dest" 2>/dev/null; then
        echo "  extracted OK"
    else
        echo "  [WARN] archive failed, falling back to file-by-file extraction..." >&2
        git ls-tree -r --name-only "${REMOTE}/${branch}" -- experiment/results/ \
        | while IFS= read -r filepath; do
            relpath="${filepath#experiment/results/}"
            destfile="$dest/$relpath"
            mkdir -p "$(dirname "$destfile")"
            if [ ! -f "$destfile" ]; then
                git show "${REMOTE}/${branch}:${filepath}" > "$destfile"
            fi
        done
        echo "  extracted OK (fallback)"
    fi

    collected=$((collected + 1))
done

echo ""
echo "============================================================"
echo " Collected $collected branch(es) -> $RESULT_BASE/"
echo "============================================================"
ls "$RESULT_BASE/" 2>/dev/null | sed 's/^/  /'

echo ""
echo "グラフ生成:"
echo "  utdelay 比較 : python3 experiment/plot_arch_comparison.py"
echo "  wait 比較    : python3 experiment/plot_wait_arch_comparison.py"
