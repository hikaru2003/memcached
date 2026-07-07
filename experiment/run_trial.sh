#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   bash experiment/run_trial.sh
#
# Description:
#   両実験（utdelay sweep + wait distribution）を短時間パラメータで実行し、
#   セットアップが正しく動作するかを確認する。
#   動作確認後、両実験結果を myfork に push する。
#
# Parameters (env vars):
#   WARMUP_SEC    - ウォームアップ秒数 (default: 30)
#   DURATION      - 計測秒数           (default: 30)
#   RUNS          - 繰り返し回数        (default: 1)
#   PAUSE_VALUES  - sweep する N 値     (default: "0 4 30")
#   MC_CPUS       - memcached CPU affinity (default: 0-3)
#   WL_CPUS       - mutilate CPU affinity  (default: 4-7)
#   SKIP_PUSH     - "1" で push をスキップ (default: "")
#
# Output:
#   experiment/results/utdelay_p999_YYYYMMDD_HHMMSS/
#   experiment/results/wait_dist_YYYYMMDD_HHMMSS/
#
# Prerequisites:
#   - setup_cloudlab.sh 実行済み（全バイナリ揃い）
#   - setup_perf_env.sh 適用済み（SMT off, performance governor, turbo off）
#   - ssh -A でログイン済み（push に必要）

set -euo pipefail

WARMUP_SEC="${WARMUP_SEC:-30}"
DURATION="${DURATION:-30}"
RUNS="${RUNS:-1}"
PAUSE_VALUES="${PAUSE_VALUES:-0 4 30}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"
SKIP_PUSH="${SKIP_PUSH:-}"

MC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MUTILATE_DIR="$(dirname "$MC_DIR")/mutilate"

echo "============================================================"
echo " run_trial.sh: 両実験の短時間動作確認"
echo "============================================================"
echo " warmup    : ${WARMUP_SEC}s"
echo " duration  : ${DURATION}s x ${RUNS} runs"
echo " N values  : ${PAUSE_VALUES}"
echo " MC_CPUS   : ${MC_CPUS}  WL_CPUS: ${WL_CPUS}"
echo "============================================================"

# バイナリ存在確認
check_binary() {
    local bin=$1
    if [ ! -x "$bin" ]; then
        echo "[ERROR] Binary not found or not executable: $bin" >&2
        echo "  Run: bash experiment/setup_cloudlab.sh" >&2
        exit 1
    fi
}
check_binary "$MC_DIR/memcached"
check_binary "$MC_DIR/memcached_master"
check_binary "$MC_DIR/memcached_wait_debug"
check_binary "$MUTILATE_DIR/mutilate_p999"
echo "[OK] All binaries found."

# CPU 環境設定（自動適用）
echo "Configuring CPU performance environment ..."
sudo bash experiment/setup_perf_env.sh

echo ""
echo "============================================================"
echo " [1/2] utdelay sweep (p50+p999)"
echo "============================================================"
cd "$MC_DIR"
MEMCACHED_BIN="$MC_DIR/memcached" \
MEMCACHED_MASTER_BIN="$MC_DIR/memcached_master" \
MUTILATE_BIN="$MUTILATE_DIR/mutilate_p999" \
WARMUP_SEC="$WARMUP_SEC" \
DURATION="$DURATION" \
RUNS="$RUNS" \
PAUSE_PER_ROUND_VALUES="$PAUSE_VALUES" \
MC_CPUS="$MC_CPUS" \
WL_CPUS="$WL_CPUS" \
bash experiment/run_utdelay_sweep_p999.sh

echo ""
echo "============================================================"
echo " [2/2] wait distribution"
echo "============================================================"
MEMCACHED_BIN="$MC_DIR/memcached_wait_debug" \
MEMCACHED_MASTER_BIN="$MC_DIR/memcached_master" \
MUTILATE_BIN="$MUTILATE_DIR/mutilate" \
WARMUP_SEC="$WARMUP_SEC" \
DURATION="$DURATION" \
RUNS="$RUNS" \
PAUSE_PER_ROUND_VALUES="$PAUSE_VALUES" \
MC_CPUS="$MC_CPUS" \
WL_CPUS="$WL_CPUS" \
bash experiment/run_wait_distribution.sh

if [ -n "$SKIP_PUSH" ]; then
    echo ""
    echo "[INFO] SKIP_PUSH=1 : push をスキップ"
    exit 0
fi

echo ""
echo "============================================================"
echo " Push results to myfork"
echo "============================================================"
echo "  pushing utdelay results ..."
bash experiment/push_results.sh

echo "  pushing wait results ..."
EXPERIMENT_TYPE=wait bash experiment/push_results.sh

echo ""
echo "============================================================"
echo " Trial complete."
echo " ann サーバでの収集:"
echo "   git fetch myfork && bash experiment/collect_results.sh"
echo "============================================================"
