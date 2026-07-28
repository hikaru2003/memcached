#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   bash experiment/run_futex_sweep_trial.sh
#
# Description:
#   run_futex_sweep.sh の動作確認用。
#   warmup/duration/runs/N値を最小限に絞り、約2〜3分で完了する。
#   本番実行前のコード・権限・バイナリの疎通確認に使う。
#
# Output:
#   experiment/results/futex_YYYYMMDD_HHMMSS/ (本番と同形式)

set -uo pipefail

export WARMUP_SEC=10
export DURATION=10
export RUNS=2
export PAUSE_PER_ROUND_VALUES="0 4 30"

echo "[trial] warmup=${WARMUP_SEC}s  duration=${DURATION}s  runs=${RUNS}  N=${PAUSE_PER_ROUND_VALUES}"
echo "[trial] 所要時間の目安: ~$(( (3 + 1) * (WARMUP_SEC + DURATION * RUNS) / 60 + 1 )) 分"
echo ""

bash experiment/run_futex_sweep.sh
