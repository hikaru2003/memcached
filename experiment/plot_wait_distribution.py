#!/usr/bin/env python3
# Usage:
#   # 単一条件（旧来互換）: wait_samples_thread*.bin が --dir 直下にある場合
#   python3 experiment/plot_wait_distribution.py --dir . --max-us 20
#
#   # 複数条件: --dir 以下に条件名サブディレクトリがある場合
#   python3 experiment/plot_wait_distribution.py \
#       --dir experiment/results/wait_dist_YYYYMMDD_HHMMSS --max-us 20
#
# Parameters:
#   --dir DIR        結果ディレクトリ（サブディレクトリ構造 or フラット）
#   --tsc-mhz MHZ   TSC周波数MHz（デフォルト: /proc/cpuinfoから自動取得、失敗時2400）
#   --max-us MAX    グラフx軸上限（µs）（デフォルト: 20）
#   --bins N        PDF用ヒストグラムbin数（デフォルト: 200）
#
# Output:
#   <DIR>/wait_distribution.pdf  — 全条件のCDF比較グラフ + 各条件のPDF
#
# Prerequisites:
#   pip install numpy matplotlib

import argparse
import glob
import os
import re
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def detect_tsc_mhz():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if "cpu MHz" in line:
                    return float(line.split(":")[1].strip())
    except Exception:
        pass
    return 2400.0


def load_condition(dirpath):
    """dirpath 内の wait_samples_thread*.bin を全スレッド合算して返す。"""
    files = sorted(glob.glob(os.path.join(dirpath, "wait_samples_thread*.bin")))
    if not files:
        return None
    arrays = [np.fromfile(f, dtype=np.uint64) for f in files]
    return np.concatenate(arrays)


def discover_conditions(base_dir):
    """
    base_dir 直下に wait_samples_thread*.bin があれば単一条件モード。
    なければサブディレクトリを条件として列挙する。
    """
    flat = glob.glob(os.path.join(base_dir, "wait_samples_thread*.bin"))
    if flat:
        return [(".", base_dir)]

    # サブディレクトリを条件順（master → N数値昇順）にソート
    subdirs = [
        d for d in os.listdir(base_dir)
        if os.path.isdir(os.path.join(base_dir, d))
        and glob.glob(os.path.join(base_dir, d, "wait_samples_thread*.bin"))
    ]

    def sort_key(name):
        if name == "master":
            return -1
        m = re.search(r"(\d+)", name)
        return int(m.group(1)) if m else 0

    subdirs.sort(key=sort_key)
    return [(name, os.path.join(base_dir, name)) for name in subdirs]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir",     default=".",   help="結果ディレクトリ")
    ap.add_argument("--tsc-mhz", type=float,    help="TSC MHz（省略で自動検出）")
    ap.add_argument("--max-us",  type=float, default=20.0)
    ap.add_argument("--bins",    type=int,   default=200)
    args = ap.parse_args()

    tsc_mhz = args.tsc_mhz if args.tsc_mhz else detect_tsc_mhz()
    print(f"TSC: {tsc_mhz:.1f} MHz", file=sys.stderr)

    conditions = discover_conditions(args.dir)
    if not conditions:
        print(f"サンプルファイルが見つかりません: {args.dir}", file=sys.stderr)
        sys.exit(1)

    data = {}
    for label, dirpath in conditions:
        samples = load_condition(dirpath)
        if samples is None or len(samples) == 0:
            print(f"  [{label}] スキップ（ファイルなし）", file=sys.stderr)
            continue
        us = samples / tsc_mhz
        data[label] = us
        print(
            f"  [{label}] n={len(us):,}  "
            f"median={np.median(us):.3f}µs  "
            f"p99={np.percentile(us,99):.3f}µs  "
            f"p999={np.percentile(us,99.9):.3f}µs",
            file=sys.stderr,
        )

    if not data:
        print("有効なサンプルがありません", file=sys.stderr)
        sys.exit(1)

    n_cond = len(data)
    cmap = plt.cm.tab10 if n_cond <= 10 else plt.cm.tab20
    colors = [cmap(i / max(n_cond - 1, 1)) for i in range(n_cond)]

    fig, ax_cdf = plt.subplots(1, 1, figsize=(9, 5))

    for idx, (label, us) in enumerate(data.items()):
        color = colors[idx]
        lw = 2.0 if label == "master" else 1.5
        ls = "--" if label == "master" else "-"

        sorted_us = np.sort(us)
        cdf = np.arange(1, len(sorted_us) + 1) / len(sorted_us)
        mask = sorted_us <= args.max_us
        ax_cdf.plot(sorted_us[mask], cdf[mask], color=color, linewidth=lw,
                    linestyle=ls, alpha=0.85, label=label)

    for p, ls, pname in [(0.50, ":", "p50"), (0.99, "--", "p99"), (0.999, "-.", "p999")]:
        ax_cdf.axhline(p, color="gray", linewidth=0.7, linestyle=ls, label=pname)
    ax_cdf.set_xlabel("Wait time (µs)")
    ax_cdf.set_ylabel("CDF")
    ax_cdf.set_title("CDF of lock wait time (per condition)")
    ax_cdf.legend(fontsize=8)

    fig.suptitle(
        f"Lock wait-time distribution  (Skylake / TSC {tsc_mhz:.0f} MHz  "
        f"SPIN_ROUNDS=30)",
        fontsize=11,
    )
    plt.tight_layout()

    out = os.path.join(args.dir, "wait_distribution.pdf")
    fig.savefig(out, dpi=150)
    print(f"Saved: {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
