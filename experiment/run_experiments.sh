#!/bin/bash
# Usage:
#   cd /users/Morisaki/memcached
#   bash experiment/run_experiments.sh
#
# Description:
#   utdelay sweep と wait distribution を順番に実行し、結果を myfork へ push する。
#   実行前に setup_perf_env.sh で CPU 環境を自動設定する。
#
# Parameters (env vars):
#   WARMUP_SEC    - ウォームアップ秒数          (default: 300)
#   DURATION      - 計測秒数                   (default: 60)
#   RUNS_UTDELAY  - utdelay の繰り返し回数      (default: 20)
#   RUNS_WAIT     - wait distribution の繰り返し回数 (default: 5)
#   MC_CPUS       - memcached CPU affinity      (default: 0-3)
#   WL_CPUS       - mutilate CPU affinity       (default: 4-7)
#   SKIP_PUSH     - "1" で push をスキップ      (default: "")
#
# Output:
#   experiment/results/utdelay_p999_YYYYMMDD_HHMMSS/
#   experiment/results/wait_dist_YYYYMMDD_HHMMSS/
#
# Prerequisites:
#   - setup_cloudlab.sh 実行済み（全バイナリ揃い）
#   - ssh -A でログイン済み（push に必要）

set -euo pipefail

WARMUP_SEC="${WARMUP_SEC:-300}"
DURATION="${DURATION:-60}"
RUNS_UTDELAY="${RUNS_UTDELAY:-20}"
RUNS_WAIT="${RUNS_WAIT:-5}"
MC_CPUS="${MC_CPUS:-0-3}"
WL_CPUS="${WL_CPUS:-4-7}"
SKIP_PUSH="${SKIP_PUSH:-}"

MC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MUTILATE_DIR="$(dirname "$MC_DIR")/mutilate"

echo "============================================================"
echo " run_experiments.sh: 本番実験 (utdelay → wait distribution)"
echo "============================================================"
echo " warmup       : ${WARMUP_SEC}s"
echo " duration     : ${DURATION}s"
echo " runs utdelay : ${RUNS_UTDELAY}"
echo " runs wait    : ${RUNS_WAIT}"
echo " MC_CPUS      : ${MC_CPUS}  WL_CPUS: ${WL_CPUS}"
echo "============================================================"

# バイナリ存在確認
check_binary() {
    local bin=$1
    if [ ! -x "$bin" ]; then
        echo "[ERROR] Binary not found: $bin" >&2
        echo "  Run: sudo bash experiment/setup_cloudlab.sh" >&2
        exit 1
    fi
}
check_binary "$MC_DIR/memcached"
check_binary "$MC_DIR/memcached_master"
check_binary "$MC_DIR/memcached_wait_debug"
check_binary "$MUTILATE_DIR/mutilate_p999"
check_binary "$MUTILATE_DIR/mutilate"
echo "[OK] All binaries found."

# CPU 環境設定（自動適用）
echo "Configuring CPU performance environment ..."
sudo bash experiment/setup_perf_env.sh

echo ""
echo "============================================================"
echo " [1/2] utdelay sweep (p50+p999)  runs=${RUNS_UTDELAY}"
echo "============================================================"
cd "$MC_DIR"
MEMCACHED_BIN="$MC_DIR/memcached" \
MEMCACHED_MASTER_BIN="$MC_DIR/memcached_master" \
MUTILATE_BIN="$MUTILATE_DIR/mutilate_p999" \
WARMUP_SEC="$WARMUP_SEC" \
DURATION="$DURATION" \
RUNS="$RUNS_UTDELAY" \
MC_CPUS="$MC_CPUS" \
WL_CPUS="$WL_CPUS" \
bash experiment/run_utdelay_sweep_p999.sh

if [ -z "$SKIP_PUSH" ]; then
    echo ""
    echo "  pushing utdelay results ..."
    bash experiment/push_results.sh
fi

echo ""
echo "============================================================"
echo " [2/2] wait distribution  runs=${RUNS_WAIT}"
echo "============================================================"
MEMCACHED_BIN="$MC_DIR/memcached_wait_debug" \
MEMCACHED_MASTER_BIN="$MC_DIR/memcached_master" \
MUTILATE_BIN="$MUTILATE_DIR/mutilate" \
WARMUP_SEC="$WARMUP_SEC" \
DURATION="$DURATION" \
RUNS="$RUNS_WAIT" \
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
echo " 実験完了。"
echo " ann サーバでの収集:"
echo "   git fetch myfork && bash experiment/collect_results.sh"
echo "============================================================"
