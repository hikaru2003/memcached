#!/bin/bash
# Usage:
#   cd /home/morisaki/Application/memcached
#   ./experiment/run_32conn_experiments.sh [adaptive_np | pause_spinlock | both]
#
# Description:
#   mutilate を -T 8 -c 4 (32コネクション) に増やして memcached 32スレッドを
#   フル活用するセットアップで実験を実行するランチャー。
#
#   デフォルト (-T 4 -c 4 = 16コネクション) では 32スレッド中 16スレッドしか
#   利用されないため、競合を最大化するためにコネクション数を32に増やす。
#
#   サブコマンド:
#     adaptive_np    - ADAPTIVE_NP vs master (get50_set50 のみ)
#     pause_spinlock - PAUSE sweep vs master (get50_set50 のみ)
#     both           - 両方順番に実行 (default)
#
# Parameters (env vars, 個別スクリプトに透過):
#   WARMUP_SEC   (default: 60)
#   DURATION     (default: 30)
#   RUNS         (default: 5)
#   MC_THREADS   (default: 32)
#   PORT         (default: 11222)
#   PAUSE_VALUES (pause_spinlock のみ, default: "0 10 30 50 70 100")
#
# Output:
#   experiment/results/adaptive_np_vs_master_YYYYMMDD_HHMMSS/   (adaptive_np)
#   experiment/results/ratio_sweep_futex_YYYYMMDD_HHMMSS/       (pause_spinlock)
#
# Prerequisites:
#   - ./memcached          : experiment/pause-spinlock ブランチのビルド
#   - ./memcached_master   : master ブランチのビルド
#   - ./memcached_adaptive_np : experiment/adaptive-np-both-locks ブランチのビルド
#   - ../mutilate/mutilate

set -uo pipefail

SUBCMD="${1:-both}"

# 32コネクションに固定
export MUT_THREADS=8
export MUT_CONNS=4

# get50_set50 のみ
export UPDATE_RATIO_VALUES="0.5"
export PAUSE_VALUES="${PAUSE_VALUES:-0 10 30 50 70 100}"

echo "============================================================"
echo " 32-connection experiment launcher"
echo " MUT_THREADS=$MUT_THREADS  MUT_CONNS=$MUT_CONNS"
echo " => $(( MUT_THREADS * MUT_CONNS )) total connections"
echo " ratio: get50_set50 only"
echo " subcmd: $SUBCMD"
echo "============================================================"

run_adaptive_np() {
    echo ""
    echo ">>> adaptive-np vs master (32conn)"
    bash experiment/run_adaptive_np_vs_master.sh
}

run_pause_spinlock() {
    echo ""
    echo ">>> pause-spinlock sweep (32conn)"
    bash experiment/run_ratio_sweep.sh
}

case "$SUBCMD" in
    adaptive_np)    run_adaptive_np ;;
    pause_spinlock) run_pause_spinlock ;;
    both)
        run_adaptive_np
        run_pause_spinlock
        ;;
    *)
        echo "Unknown subcommand: $SUBCMD" >&2
        echo "Usage: $0 [adaptive_np | pause_spinlock | both]" >&2
        exit 1
        ;;
esac

echo ""
echo "============================================================"
echo " 32-conn experiments done."
echo "============================================================"
