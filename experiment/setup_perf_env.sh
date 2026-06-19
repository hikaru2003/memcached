#!/bin/bash
# Usage:
#   sudo bash experiment/setup_perf_env.sh
#
# Description:
#   実験前の CPU 環境統一スクリプト。annサーバの設定を基準として以下を適用する。
#     1. SMT (Hyper-Threading) を無効化
#     2. CPU 周波数ガバナーを performance に設定（最大周波数固定）
#     3. Turbo Boost を無効化
#   設定はリブートで元に戻る（永続化しない）。
#
# Output:
#   標準出力に各設定の適用結果と確認値を表示する
#
# Prerequisites:
#   - root 権限（sudo）
#   - Intel CPU (intel_pstate / intel_cpufreq ドライバ)

set -uo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] root 権限が必要です。sudo で実行してください。" >&2
    exit 1
fi

echo "============================================================"
echo " CPU performance environment setup"
echo " (based on annサーバ: SMT=off, governor=performance, turbo=off)"
echo "============================================================"

# ---- 1. SMT 無効化 ----
echo ""
echo "[1/3] SMT (Hyper-Threading) ..."
SMT_CTRL="/sys/devices/system/cpu/smt/control"
if [ -f "$SMT_CTRL" ]; then
    echo off > "$SMT_CTRL"
    smt_state=$(cat /sys/devices/system/cpu/smt/active)
    echo "  smt/control  : $(cat $SMT_CTRL)"
    echo "  smt/active   : $smt_state  (0=off が正常)"
    [ "$smt_state" = "0" ] && echo "  [OK]" || echo "  [WARN] SMT が無効化されていない可能性があります"
else
    echo "  [SKIP] $SMT_CTRL が存在しない（SMT非対応 or すでに無効）"
fi

# ---- 2. 周波数ガバナー: performance ----
echo ""
echo "[2/3] CPU frequency governor -> performance ..."
failed=0
for gov_path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$gov_path" ] || continue
    echo performance > "$gov_path" || { failed=1; break; }
done

if [ "$failed" = "0" ]; then
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    cur=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A")
    max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "N/A")
    echo "  governor     : $gov"
    echo "  cur_freq     : ${cur} Hz  ($(( ${cur:-0} / 1000 )) MHz)"
    echo "  max_freq     : ${max} Hz  ($(( ${max:-0} / 1000 )) MHz)"
    echo "  [OK]"
else
    # cpupower フォールバック
    if command -v cpupower &>/dev/null; then
        cpupower frequency-set -g performance 2>&1 | tail -2
        echo "  (applied via cpupower)"
    else
        echo "  [WARN] scaling_governor への書き込み失敗。cpupower もなし。"
        echo "  手動: echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
    fi
fi

# ---- 3. Turbo Boost 無効化 ----
echo ""
echo "[3/3] Turbo Boost -> off ..."
NO_TURBO="/sys/devices/system/cpu/intel_pstate/no_turbo"
BOOST="/sys/devices/system/cpu/cpufreq/boost"

if [ -f "$NO_TURBO" ]; then
    echo 1 > "$NO_TURBO"
    echo "  intel_pstate/no_turbo : $(cat $NO_TURBO)  (1=turbo OFF が正常)"
    echo "  [OK]"
elif [ -f "$BOOST" ]; then
    echo 0 > "$BOOST"
    echo "  cpufreq/boost : $(cat $BOOST)  (0=turbo OFF が正常)"
    echo "  [OK]"
else
    echo "  [WARN] Turbo Boost 制御ファイルが見つかりません。"
    echo "  手動: echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo"
fi

# ---- 確認サマリ ----
echo ""
echo "============================================================"
echo " 確認サマリ"
echo "============================================================"
echo "  logical CPUs  : $(nproc)"
lscpu | grep -E "Thread\(s\)|Core\(s\)|Socket" | sed 's/^/  /'
echo "  governor      : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo N/A)"
cur=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0)
echo "  cur_freq      : $(( cur / 1000 )) MHz"
echo "  max_freq      : $(( max / 1000 )) MHz"
no_turbo_val=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo N/A)
echo "  turbo_off     : $no_turbo_val"
smt_active=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo N/A)
echo "  smt_active    : $smt_active"
echo "============================================================"
echo ""
echo "設定完了。この設定はリブートで元に戻ります。"
echo "実験後に元に戻す場合:"
echo "  echo on  > /sys/devices/system/cpu/smt/control"
echo "  echo 0   > /sys/devices/system/cpu/intel_pstate/no_turbo"
echo "  echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
