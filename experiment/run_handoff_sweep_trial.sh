#!/bin/bash
# Usage:
#   cd ~/Application/memcached
#   bash experiment/run_handoff_sweep_trial.sh
#
# Description:
#   run_handoff_sweep.sh の動作確認用ショートランナー。
#   warmup/duration/runs/N値を小さくして素早く完走できるかを確認する。
#
# Parameters (env vars):
#   すべて run_handoff_sweep.sh に準ずる（上書き可能）
#
# Output:
#   experiment/results/handoff_YYYYMMDD_HHMMSS/ (trialデータ)

WARMUP_SEC="${WARMUP_SEC:-10}" \
DURATION="${DURATION:-10}" \
RUNS="${RUNS:-2}" \
PAUSE_PER_ROUND_VALUES="${PAUSE_PER_ROUND_VALUES:-0 4 30}" \
    bash experiment/run_handoff_sweep.sh
