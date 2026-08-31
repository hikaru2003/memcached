#!/bin/bash
# Usage:
#   sudo bash /local/setup_memcached.sh   # CloudLab pg.Execute 経由（自動実行）
#   sudo bash experiment/setup_cloudlab.sh  # 手動再実行
#
# Description:
#   CloudLab サーバ（Ubuntu 24.04）での memcached + mutilate セットアップ。
#   - OS パッケージのインストール（apt のみ）
#   - results ブランチを /users/Morisaki/memcached/ にクローン（実験スクリプト用）
#   - memcached バイナリを3ブランチからビルドして /users/Morisaki/memcached/ に配置
#       experiment/mysql-like-utdelay -> memcached  (utdelay計測用)
#       master                        -> memcached_master       (baseline)
#       debug/wait-time               -> memcached_wait_debug   (wait分布計測用)
#       debug/handoff-latency         -> memcached_handoff_debug (handoffレイテンシ計測用)
#   - leverich/mutilate (standard + p999) のビルド
#   - アーキテクチャ判定・ラッパースクリプト生成
#
# Parameters (env vars):
#   SKIP_PKG   - "1" でパッケージインストールをスキップ (default: "")
#   SKIP_BUILD - "1" でビルドをスキップ            (default: "")
#
# Output:
#   /users/Morisaki/memcached/                   - results ブランチのクローン（実験作業ディレクトリ）
#   /users/Morisaki/memcached/memcached          - utdelay バイナリ
#   /users/Morisaki/memcached/memcached_master        - master バイナリ
#   /users/Morisaki/memcached/memcached_wait_debug    - wait-time バイナリ
#   /users/Morisaki/memcached/memcached_handoff_debug - handoff latency バイナリ
#   /users/Morisaki/mutilate/mutilate            - mutilate バイナリ
#   /users/Morisaki/mutilate/mutilate_p999       - p50+p999 対応バイナリ
#   /users/Morisaki/run_utdelay_experiment.sh    - 実験実行用ラッパー
#
# Prerequisites:
#   - sudo 権限があること
#   - インターネット接続（github.com）

set -uo pipefail

SKIP_PKG="${SKIP_PKG:-}"
SKIP_BUILD="${SKIP_BUILD:-}"

BASE_DIR="/users/Morisaki"
MC_REPO="https://github.com/hikaru2003/memcached.git"
MUTILATE_REPO="https://github.com/leverich/mutilate.git"

MC_DIR="$BASE_DIR/memcached"          # results ブランチ（スクリプト用）
UTDELAY_BUILD_DIR="$BASE_DIR/memcached_utdelay_src"   # ビルド専用
MUTILATE_DIR="$BASE_DIR/mutilate"

echo "============================================================"
echo " CloudLab setup: memcached + mutilate"
echo "============================================================"
echo " BASE_DIR  : $BASE_DIR"
echo " MC_DIR    : $MC_DIR  (results branch)"
echo "============================================================"

# ---- OS パッケージ ----
if [ -z "$SKIP_PKG" ]; then
    echo ""
    echo "[1/4] Installing OS packages ..."
    # Ubuntu 24.04 (CloudLab default, verified on all target arch nodes)
    sudo apt update -qq
    sudo apt install -y \
        git build-essential automake autoconf pkg-config \
        libevent-dev \
        scons gengetopt libboost-dev libzmq3-dev \
        python3-numpy python3-matplotlib \
        util-linux htop
    echo "[1/4] Done."
else
    echo "[1/4] Skipped (SKIP_PKG=1)"
fi

mkdir -p "$BASE_DIR"

# ---- memcached clone & build ----
echo ""
echo "[2/4] Setting up memcached ..."

# results ブランチ（実験スクリプト用）をクローン
if [ -d "$MC_DIR/.git" ]; then
    echo "  Already cloned (results). Pulling ..."
    git -C "$MC_DIR" fetch origin
    git -C "$MC_DIR" checkout results
    git -C "$MC_DIR" pull origin results || true
else
    git clone --branch results "$MC_REPO" "$MC_DIR"
fi

if [ -z "$SKIP_BUILD" ]; then
    # utdelay バイナリのビルド（experiment/mysql-like-utdelay ブランチ）
    echo "  Building memcached (utdelay branch) ..."
    if [ -d "$UTDELAY_BUILD_DIR/.git" ]; then
        git -C "$UTDELAY_BUILD_DIR" pull origin experiment/mysql-like-utdelay 2>&1 | tail -2 || true
    else
        git clone --branch experiment/mysql-like-utdelay "$MC_REPO" "$UTDELAY_BUILD_DIR"
    fi
    cd "$UTDELAY_BUILD_DIR"
    ./autogen.sh 2>&1 | tail -3
    ./configure 2>&1 | tail -5
    make -j"$(nproc)" 2>&1 | tail -5
    if [ ! -x "$UTDELAY_BUILD_DIR/memcached" ]; then
        echo "[ERROR] memcached (utdelay) build failed" >&2; exit 1
    fi
    cp "$UTDELAY_BUILD_DIR/memcached" "$MC_DIR/memcached"
    echo "  Built: $MC_DIR/memcached"
    cd - >/dev/null

    # master バイナリのビルド（baseline 比較用）
    echo "  Building memcached_master (master branch) ..."
    MASTER_BUILD_DIR="${BASE_DIR}/memcached_master_src"
    if [ -d "$MASTER_BUILD_DIR/.git" ]; then
        git -C "$MASTER_BUILD_DIR" pull origin master 2>&1 | tail -2 || true
    else
        git clone --branch master "$MC_REPO" "$MASTER_BUILD_DIR"
    fi
    cd "$MASTER_BUILD_DIR"
    ./autogen.sh 2>&1 | tail -3
    ./configure 2>&1 | tail -5
    make -j"$(nproc)" 2>&1 | tail -5
    if [ ! -x "$MASTER_BUILD_DIR/memcached" ]; then
        echo "[ERROR] memcached_master build failed" >&2; exit 1
    fi
    cp "$MASTER_BUILD_DIR/memcached" "$MC_DIR/memcached_master"
    echo "  Built: $MC_DIR/memcached_master"
    cd - >/dev/null

    # debug/wait-time バイナリのビルド（wait_distribution 実験用）
    echo "  Building memcached_wait_debug (debug/wait-time branch) ..."
    WAIT_BUILD_DIR="${BASE_DIR}/memcached_wait_src"
    if [ -d "$WAIT_BUILD_DIR/.git" ]; then
        git -C "$WAIT_BUILD_DIR" fetch origin debug/wait-time 2>&1 | tail -2 || true
        git -C "$WAIT_BUILD_DIR" checkout debug/wait-time 2>&1 | tail -1 || true
        git -C "$WAIT_BUILD_DIR" pull origin debug/wait-time 2>&1 | tail -2 || true
    else
        git clone --branch debug/wait-time "$MC_REPO" "$WAIT_BUILD_DIR"
    fi
    cd "$WAIT_BUILD_DIR"
    ./autogen.sh 2>&1 | tail -3
    ./configure 2>&1 | tail -5
    make -j"$(nproc)" 2>&1 | tail -5
    if [ ! -x "$WAIT_BUILD_DIR/memcached" ]; then
        echo "[ERROR] memcached_wait_debug build failed" >&2; exit 1
    fi
    cp "$WAIT_BUILD_DIR/memcached" "$MC_DIR/memcached_wait_debug"
    echo "  Built: $MC_DIR/memcached_wait_debug"
    cd - >/dev/null

    # debug/handoff-latency バイナリのビルド（handoff latency 実験用）
    echo "  Building memcached_handoff_debug (debug/handoff-latency branch) ..."
    HANDOFF_BUILD_DIR="${BASE_DIR}/memcached_handoff_src"
    if [ -d "$HANDOFF_BUILD_DIR/.git" ]; then
        git -C "$HANDOFF_BUILD_DIR" fetch origin debug/handoff-latency 2>&1 | tail -2 || true
        git -C "$HANDOFF_BUILD_DIR" checkout debug/handoff-latency 2>&1 | tail -1 || true
        git -C "$HANDOFF_BUILD_DIR" pull origin debug/handoff-latency 2>&1 | tail -2 || true
    else
        git clone --branch debug/handoff-latency "$MC_REPO" "$HANDOFF_BUILD_DIR"
    fi
    cd "$HANDOFF_BUILD_DIR"
    ./autogen.sh 2>&1 | tail -3
    ./configure 2>&1 | tail -5
    make -j"$(nproc)" 2>&1 | tail -5
    if [ ! -x "$HANDOFF_BUILD_DIR/memcached" ]; then
        echo "[ERROR] memcached_handoff_debug build failed" >&2; exit 1
    fi
    cp "$HANDOFF_BUILD_DIR/memcached" "$MC_DIR/memcached_handoff_debug"
    echo "  Built: $MC_DIR/memcached_handoff_debug"
    cd - >/dev/null
fi
echo "[2/4] Done."

# ---- mutilate clone, patch & build ----
echo ""
echo "[3/4] Setting up mutilate ..."
if [ -d "$MUTILATE_DIR/.git" ]; then
    echo "  Already cloned."
else
    git clone "$MUTILATE_REPO" "$MUTILATE_DIR"
fi

if [ -z "$SKIP_BUILD" ]; then
    echo "  Patching SConstruct (Python2 print -> Python3) ..."
    cd "$MUTILATE_DIR"

    # Python 2 print文をPython 3に修正（upstream leverich/mutilate はPython2のまま）
    sed -i \
        -e 's/print "A compiler with C++11 support is required\."/print("A compiler with C++11 support is required.")/g' \
        -e 's/print "Checking for gengetopt\.\.\.",/print("Checking for gengetopt...", end=" ")/g' \
        -e 's/print "not found (required)"/print("not found (required)")/g' \
        -e 's/else: print "found"/else: print("found")/g' \
        -e 's/print "libevent required"/print("libevent required")/g' \
        -e 's/print "pthread required"/print("pthread required")/g' \
        SConstruct

    echo "  Building mutilate ..."
    scons -j"$(nproc)" 2>&1 | tail -5
    if [ ! -x "$MUTILATE_DIR/mutilate" ]; then
        echo "[ERROR] mutilate build failed" >&2; exit 1
    fi
    echo "  Built: $MUTILATE_DIR/mutilate"

    # p50+p999 対応バイナリのビルド（Python で ConnectionStats.h を直接編集）
    echo "  Building mutilate_p999 (p50+p999 patch via Python) ..."
    cp ConnectionStats.h ConnectionStats.h.orig
    python3 - << 'PYEOF'
import sys

with open("ConnectionStats.h") as f:
    txt = f.read()

if '"50th"' in txt:
    print("  ConnectionStats.h already has p50/p999 patch")
    sys.exit(0)

# 1. print_header format string: 9 -> 11 %7s
txt = txt.replace(
    '%-7s %7s %7s %7s %7s %7s %7s %7s %7s\n"',
    '%-7s %7s %7s %7s %7s %7s %7s %7s %7s %7s %7s\n"'
)
# 2. print_header column names: add 50th and 999th
txt = txt.replace(
    '           "90th", "95th", "99th");',
    '           "50th", "90th", "95th", "99th", "999th");'
)
# 3. All printf format strings: 8 floats -> 10 floats
txt = txt.replace(
    '%-7s %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f"',
    '%-7s %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f"'
)
# 4. Zero cases: 8 zeros -> 10 zeros
txt = txt.replace(
    '             tag, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);',
    '             tag, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);'
)
# 5. AdaptiveSampler/copy[] args: add p50 and p999
txt = txt.replace(
    '           copy[(l*10) / 100],\n           copy[(l*90) / 100], copy[(l*95) / 100], copy[(l*99) / 100]\n           );',
    '           copy[(l*10) / 100],\n           copy[(l*50) / 100], copy[(l*90) / 100], copy[(l*95) / 100],\n           copy[(l*99) / 100], copy[(l*999) / 1000]\n           );'
)
# 6. HistogramSampler/LogHistogramSampler get_nth: add get_nth(50) and get_nth(99.9)
txt = txt.replace(
    '           sampler.get_nth(10), sampler.get_nth(90),\n           sampler.get_nth(95), sampler.get_nth(99));',
    '           sampler.get_nth(10), sampler.get_nth(50), sampler.get_nth(90),\n           sampler.get_nth(95), sampler.get_nth(99), sampler.get_nth(99.9));'
)

with open("ConnectionStats.h", "w") as f:
    f.write(txt)

print("  ConnectionStats.h patched: p50 (50th) and p999 (999th) added")
PYEOF

    if grep -q '"50th"' ConnectionStats.h; then
        scons -j"$(nproc)" 2>&1 | tail -3
        if [ -x "$MUTILATE_DIR/mutilate" ]; then
            cp mutilate mutilate_p999
            echo "  Built: $MUTILATE_DIR/mutilate_p999"
        else
            echo "[WARN] mutilate_p999 build failed"
        fi
    else
        echo "[WARN] Python patch did not apply correctly, skipping mutilate_p999"
    fi
    cp ConnectionStats.h.orig ConnectionStats.h
    rm -f ConnectionStats.h.orig
    scons -j"$(nproc)" 2>&1 | tail -2

    cd - >/dev/null
fi
echo "[3/4] Done."

# ---- CPU topology & 推奨 env var 出力 ----
echo ""
echo "[4/4] Detecting CPU topology ..."

cpu_model=$(grep "^model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')

echo "  CPU model  : $cpu_model"

# アーキテクチャ判定
# PAUSE実測値（-O2コンパイル、pause_cycle_count.c 実測）:
#   Ivy Bridge≈15cyc, Broadwell≈10cyc, Skylake≈124cyc, IceLake≈39cyc, Emerald≈37cyc
# CloudLab hardware type → CPU model の対応:
#   c8220(Ivy): Xeon E5-2650 v2  /  xl170(Broadwell): Xeon E5-2640 v4
#   c220g5(Skylake): Xeon Silver 4114  /  sm110(IceLake): Xeon Gold 6338
#   c6620(Emerald): Xeon Gold 6554S
if echo "$cpu_model" | grep -qiE "E5-2[0-9]+.*v4|E7-.*v4|broadwell"; then
    ARCH_NAME="broadwell"
    PAUSE_NOTE="Broadwell(xl170): PAUSE~10cyc"
elif echo "$cpu_model" | grep -qiE "E5-2[0-9]+.*v2|E7-.*v2|E3-.*v2"; then
    ARCH_NAME="ivybridge"
    PAUSE_NOTE="Ivy Bridge(c8220): PAUSE~15cyc"
elif echo "$cpu_model" | grep -qiE "6554|6548|6538|emerald"; then
    ARCH_NAME="emeraldrapids"
    PAUSE_NOTE="Emerald Rapids(c6620): PAUSE~37cyc"
elif echo "$cpu_model" | grep -qiE "6338|6348|6354|Silver 4[3-9][0-9]{2}|ice lake|icelake"; then
    ARCH_NAME="icelake"
    PAUSE_NOTE="Ice Lake(sm110): PAUSE~39cyc"
elif echo "$cpu_model" | grep -qiE "Silver 4114|Silver 41[0-9]{2}|Gold 5[12][0-9]{2}|skylake"; then
    ARCH_NAME="skylake"
    PAUSE_NOTE="Skylake(c220g5): PAUSE~124cyc"
else
    ARCH_NAME="unknown"
    PAUSE_NOTE="Unknown arch -- PAUSE cycles unknown, verify manually"
fi

MC_CPUS_REC="0-3"
WL_CPUS_REC="4-7"

echo "  Arch guess : $ARCH_NAME  ($PAUSE_NOTE)"
echo "  MC_CPUS    : $MC_CPUS_REC  WL_CPUS: $WL_CPUS_REC"

# ---- ラッパースクリプト生成 ----
WRAPPER="$BASE_DIR/run_utdelay_experiment.sh"
cat > "$WRAPPER" << WRAPPER_EOF
#!/bin/bash
# Auto-generated by setup_cloudlab.sh
# Architecture: ${ARCH_NAME}
# CPU model: ${cpu_model}
# Run: bash ~/run_utdelay_experiment.sh

set -uo pipefail

MC_DIR="$MC_DIR"
MUTILATE_DIR="$MUTILATE_DIR"

export MEMCACHED_BIN="\${MC_DIR}/memcached"
export MEMCACHED_MASTER_BIN="\${MC_DIR}/memcached_master"
export MUTILATE_BIN="\${MUTILATE_DIR}/mutilate_p999"
export MC_THREADS=4
export MUT_THREADS=4
export MUT_CONNS=1
export DEPTH=32
export RECORDS=1
export UPDATE_RATIO=0.5
export WARMUP_SEC=300
export DURATION=60
export RUNS=20
export SPIN_ROUNDS=30
export PAUSE_PER_ROUND_VALUES="0 1 2 3 4 5 6 7 8 9 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100 150 200"
export PORT=11222
export MC_CPUS="${MC_CPUS_REC}"
export WL_CPUS="${WL_CPUS_REC}"

echo "Architecture : ${ARCH_NAME}"
echo "PAUSE rec    : ${PAUSE_NOTE}"
echo ""

cd "\${MC_DIR}"
bash experiment/run_utdelay_sweep_p999.sh
WRAPPER_EOF
chmod +x "$WRAPPER"

# ---- htop 設定の配置 ----
HTOP_CONF_SRC="$MC_DIR/experiment/config/htop/htoprc"
HTOP_CONF_DST="$BASE_DIR/.config/htop/htoprc"
if [ -f "$HTOP_CONF_SRC" ]; then
    mkdir -p "$(dirname "$HTOP_CONF_DST")"
    cp "$HTOP_CONF_SRC" "$HTOP_CONF_DST"
    echo "  htop config: $HTOP_CONF_DST"
fi

echo ""
echo "[4/4] Done."

# ---- git ユーザ設定 ----
git config --global user.name "hikaru2003"
git config --global user.email "hikaru.morisaki.0316@gmail.com"

# ---- myfork remote を SSH URL で設定（chown 前に実行: git safe.directory 問題回避）----
if git -C "$MC_DIR" remote | grep -q "^myfork$"; then
    git -C "$MC_DIR" remote set-url myfork git@github.com:hikaru2003/memcached.git
else
    git -C "$MC_DIR" remote add myfork git@github.com:hikaru2003/memcached.git
fi

chown -R Morisaki "$BASE_DIR" 2>/dev/null || true

echo ""
echo "============================================================"
echo " Setup complete!"
echo "============================================================"
echo ""
echo " memcached (utdelay) : $MC_DIR/memcached"
echo " memcached_master    : $MC_DIR/memcached_master"
echo " memcached_wait_debug: $MC_DIR/memcached_wait_debug"
echo " mutilate            : $MUTILATE_DIR/mutilate"
echo " mutilate_p999       : $MUTILATE_DIR/mutilate_p999"
echo " wrapper             : $WRAPPER"
echo ""
echo " Run trial (both experiments, short params):"
echo "   cd $MC_DIR && bash experiment/run_trial.sh"
echo ""
echo " Run full experiments:"
echo "   bash ~/run_utdelay_experiment.sh                          # utdelay sweep"
echo "   cd $MC_DIR && bash experiment/run_wait_distribution.sh   # wait distribution"
echo ""
echo " After experiment, push results:"
echo "   cd $MC_DIR && bash experiment/push_results.sh"
echo "   cd $MC_DIR && EXPERIMENT_TYPE=wait bash experiment/push_results.sh"
echo ""
echo " ※ GitHub push は ssh -A でログインすれば agent forwarding で認証される"
echo "============================================================"
