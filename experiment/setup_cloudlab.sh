#!/bin/bash
# Usage:
#   # 素のCloudLabサーバ上で実行（memcachedリポジトリをclone前でも可）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/hikaru2003/memcached/experiment/mysql-like-utdelay/experiment/setup_cloudlab.sh)
#
#   # すでにclone済みの場合:
#   bash ~/Application/memcached/experiment/setup_cloudlab.sh
#
# Description:
#   CloudLab サーバ（Ubuntu/Debian）での memcached + mutilate セットアップ。
#   - OS パッケージのインストール
#   - hikaru2003/memcached (experiment/mysql-like-utdelay) のビルド
#   - leverich/mutilate のビルド（Python3 対応 SConstruct パッチ適用）
#   - CPU トポロジーの表示と推奨 env var の出力
#
# Parameters (env vars):
#   BASE_DIR   - 作業ディレクトリ親                (default: ~/Application)
#   MC_BRANCH  - memcached ブランチ                (default: experiment/mysql-like-utdelay)
#   SKIP_PKG   - "1" でパッケージインストールをスキップ (default: "")
#   SKIP_BUILD - "1" でビルドをスキップ            (default: "")
#
# Output:
#   $BASE_DIR/memcached/memcached      - memcached バイナリ
#   $BASE_DIR/mutilate/mutilate        - mutilate バイナリ
#   ~/run_utdelay_experiment.sh        - 実験実行用ラッパースクリプト（arch別設定済み）
#
# Prerequisites:
#   - sudo 権限があること
#   - インターネット接続（github.com）
#   - 結果を push する場合は GitHub 認証設定が必要（スクリプト末尾の案内を参照）

set -uo pipefail

BASE_DIR="${BASE_DIR:-$HOME/Application}"
MC_BRANCH="${MC_BRANCH:-experiment/mysql-like-utdelay}"
SKIP_PKG="${SKIP_PKG:-}"
SKIP_BUILD="${SKIP_BUILD:-}"

MC_REPO="https://github.com/hikaru2003/memcached.git"
MUTILATE_REPO="https://github.com/leverich/mutilate.git"

MC_DIR="$BASE_DIR/memcached"
MUTILATE_DIR="$BASE_DIR/mutilate"

echo "============================================================"
echo " CloudLab setup: memcached + mutilate"
echo "============================================================"
echo " BASE_DIR  : $BASE_DIR"
echo " MC_BRANCH : $MC_BRANCH"
echo "============================================================"

# ---- OS パッケージ ----
if [ -z "$SKIP_PKG" ]; then
    echo ""
    echo "[1/4] Installing OS packages ..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y \
            git build-essential automake autoconf pkg-config \
            libevent-dev \
            scons gengetopt libboost-dev libzmq3-dev \
            util-linux cpuid 2>/dev/null || \
        sudo apt-get install -y \
            git build-essential automake autoconf pkg-config \
            libevent-dev \
            scons gengetopt libboost-dev \
            util-linux
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y \
            git gcc gcc-c++ make automake autoconf pkgconfig \
            libevent-devel \
            scons gengetopt boost-devel zeromq-devel \
            util-linux
    elif command -v yum &>/dev/null; then
        sudo yum install -y \
            git gcc gcc-c++ make automake autoconf pkgconfig \
            libevent-devel \
            scons gengetopt boost-devel zeromq-devel \
            util-linux
    else
        echo "[WARN] Unknown package manager. Install manually:" >&2
        echo "  git, gcc, make, automake, autoconf, libevent-dev," >&2
        echo "  scons, gengetopt, libboost-dev, libzmq3-dev" >&2
    fi
    echo "[1/4] Done."
else
    echo "[1/4] Skipped (SKIP_PKG=1)"
fi

mkdir -p "$BASE_DIR"

# ---- memcached clone & build ----
echo ""
echo "[2/4] Setting up memcached ..."
if [ -d "$MC_DIR/.git" ]; then
    echo "  Already cloned. Fetching & checking out $MC_BRANCH ..."
    git -C "$MC_DIR" fetch origin
    git -C "$MC_DIR" checkout "$MC_BRANCH"
    git -C "$MC_DIR" pull origin "$MC_BRANCH" || true
else
    git clone --branch "$MC_BRANCH" "$MC_REPO" "$MC_DIR"
fi

if [ -z "$SKIP_BUILD" ]; then
    echo "  Building memcached ..."
    cd "$MC_DIR"
    autoreconf -fi 2>&1 | tail -3
    ./configure 2>&1 | tail -5
    make -j"$(nproc)" 2>&1 | tail -5
    if [ ! -x "$MC_DIR/memcached" ]; then
        echo "[ERROR] memcached build failed" >&2; exit 1
    fi
    echo "  Built: $MC_DIR/memcached"
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
    cd - >/dev/null
fi
echo "[3/4] Done."

# ---- CPU topology & 推奨 env var 出力 ----
echo ""
echo "[4/4] Detecting CPU topology ..."

cpu_model=$(grep "^model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')
sockets=$(lscpu | grep "^Socket(s):" | awk '{print $2}')
cores_per_socket=$(lscpu | grep "^Core(s) per socket:" | awk '{print $4}')
threads_per_core=$(lscpu | grep "^Thread(s) per core:" | awk '{print $4}')
total_logical=$(nproc)
total_physical=$(( sockets * cores_per_socket ))

echo "  CPU model  : $cpu_model"
echo "  Sockets    : $sockets"
echo "  Phys cores : $total_physical  (${cores_per_socket}/socket)"
echo "  HT threads : $threads_per_core per core  (${total_logical} logical total)"

# アーキテクチャ判定 + 推奨 PAUSE_PER_ROUND_VALUES
if echo "$cpu_model" | grep -qiE "broadwell|E5.*v4|E7.*v4|D-15[0-9][0-9]"; then
    ARCH_NAME="broadwell"
    PAUSE_REC="0 1 2 5 10 20 30 50 80 100"
    PAUSE_NOTE="Broadwell: PAUSE≈10 cycles, wider sweep"
elif echo "$cpu_model" | grep -qiE "ivy|E5.*v2|E7.*v2|E3.*v2|i[357]-[34][0-9]{3}"; then
    ARCH_NAME="ivybridge"
    PAUSE_REC="0 1 2 5 10 20 30 50 80 100"
    PAUSE_NOTE="Ivy Bridge: PAUSE≈10 cycles, wider sweep"
elif echo "$cpu_model" | grep -qiE "emerald|6[0-9]{3}[NPHC]|8[5-9][0-9]{2}[A-Z]"; then
    ARCH_NAME="emeraldrapids"
    PAUSE_REC="0 1 2 3 5 8 10 15 20"
    PAUSE_NOTE="Emerald Rapids: PAUSE≈140 cycles, narrower sweep"
elif echo "$cpu_model" | grep -qiE "ice lake|8[23][0-9]{2}[A-Z]|icelake"; then
    ARCH_NAME="icelake"
    PAUSE_REC="0 1 2 3 5 8 10 15 20"
    PAUSE_NOTE="Ice Lake: PAUSE≈140 cycles, narrower sweep"
elif echo "$cpu_model" | grep -qiE "skylake|silver 4[01][0-9]{2}|gold 5[12][0-9]{2}|gold 6[12][0-9]{2}|platinum 8[12][0-9]{2}"; then
    ARCH_NAME="skylake"
    PAUSE_REC="0 1 2 3 5 8 10 15 20"
    PAUSE_NOTE="Skylake: PAUSE≈140 cycles, narrower sweep"
else
    ARCH_NAME="unknown"
    PAUSE_REC="0 1 2 3 5 10 20 30 50"
    PAUSE_NOTE="Unknown arch — verify manually"
fi

echo "  Arch guess : $ARCH_NAME  ($PAUSE_NOTE)"

# MC(4スレッド) + mutilate(4スレッド) = 8物理コア必要
# 物理コアを前半/後半に割り当て（HT兄弟は使わない）
if [ "$total_physical" -ge 8 ]; then
    MC_CPUS_REC="0-3"
    WL_CPUS_REC="4-7"
else
    MC_CPUS_REC="0-$((total_physical/2 - 1))"
    WL_CPUS_REC="$((total_physical/2))-$((total_physical - 1))"
fi

echo "  Suggested  : MC_CPUS=$MC_CPUS_REC  WL_CPUS=$WL_CPUS_REC"

# ---- ラッパースクリプト生成 ----
WRAPPER="$HOME/run_utdelay_experiment.sh"
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
export MUTILATE_BIN="\${MUTILATE_DIR}/mutilate"
export MC_THREADS=4
export MUT_THREADS=4
export MUT_CONNS=1
export DEPTH=32
export RECORDS=1
export UPDATE_RATIO=0.5
export WARMUP_SEC=180
export DURATION=60
export RUNS=10
export SPIN_ROUNDS=30
export PAUSE_PER_ROUND_VALUES="${PAUSE_REC}"
export PORT=11222
export MC_CPUS="${MC_CPUS_REC}"
export WL_CPUS="${WL_CPUS_REC}"

echo "Architecture : ${ARCH_NAME}"
echo "PAUSE rec    : ${PAUSE_NOTE}"
echo ""

cd "\${MC_DIR}"
bash experiment/run_utdelay_sweep.sh
WRAPPER_EOF
chmod +x "$WRAPPER"

echo ""
echo "[4/4] Done."

# ---- git 認証案内 ----
echo ""
echo "============================================================"
echo " Setup complete!"
echo "============================================================"
echo ""
echo " memcached : $MC_DIR/memcached"
echo " mutilate  : $MUTILATE_DIR/mutilate"
echo " wrapper   : $WRAPPER"
echo ""
echo " Run experiment:"
echo "   bash ~/run_utdelay_experiment.sh"
echo ""
echo " After experiment, push results:"
echo "   bash $MC_DIR/experiment/push_results.sh"
echo ""
echo "------------------------------------------------------------"
echo " GitHub push 設定（初回のみ）:"
echo "   # SSH key 生成 & 登録"
echo "   ssh-keygen -t ed25519 -C 'cloudlab-${ARCH_NAME}' -f ~/.ssh/id_ed25519_github -N ''"
echo "   cat ~/.ssh/id_ed25519_github.pub"
echo "   # → https://github.com/settings/keys に追加"
echo "   git -C $MC_DIR remote set-url myfork git@github.com:hikaru2003/memcached.git"
echo "   ssh -T git@github.com  # 接続確認"
echo "------------------------------------------------------------"
