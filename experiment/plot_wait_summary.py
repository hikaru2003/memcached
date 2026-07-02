#!/usr/bin/env python3
# Usage:
#   python3 experiment/plot_wait_summary.py \
#       --dir experiment/results/wait_dist_YYYYMMDD_HHMMSS \
#       [--tsc-mhz MHZ] [--out PATH]
#
# Parameters:
#   --dir DIR       wait_dist 実験結果ディレクトリ
#   --tsc-mhz MHZ  TSC周波数MHz（省略で /proc/cpuinfo から自動取得）
#   --out PATH     出力画像パス（省略で <DIR>/wait_summary.png）
#
# Output:
#   wait_summary.png — QPS・median/p99/p999 wait time の N 別比較グラフ
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
import matplotlib.ticker as ticker


def detect_tsc_mhz():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if "cpu MHz" in line:
                    return float(line.split(":")[1].strip())
    except Exception:
        pass
    return 2400.0


def sort_key(name):
    if name == "master":
        return -1
    m = re.search(r"(\d+)", name)
    return int(m.group(1)) if m else 0


def load_condition(dirpath, tsc_mhz):
    """stats.txt から QPS、bin ファイルからパーセンタイルを取得する。"""
    # QPS
    qps = None
    stats_path = os.path.join(dirpath, "stats.txt")
    if os.path.exists(stats_path):
        for line in open(stats_path):
            m = re.search(r"mean_qps=(\d+)", line)
            if m:
                qps = int(m.group(1))

    # wait time パーセンタイル
    files = sorted(glob.glob(os.path.join(dirpath, "wait_samples_thread*.bin")))
    if not files:
        return qps, None, None, None

    samples = np.concatenate([np.fromfile(f, dtype=np.uint64) for f in files])
    us = samples / tsc_mhz
    median = float(np.median(us))
    p99    = float(np.percentile(us, 99))
    p999   = float(np.percentile(us, 99.9))
    return qps, median, p99, p999


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir",     required=True)
    ap.add_argument("--tsc-mhz", type=float)
    ap.add_argument("--out",     default=None)
    args = ap.parse_args()

    tsc_mhz = args.tsc_mhz if args.tsc_mhz else detect_tsc_mhz()
    print(f"TSC: {tsc_mhz:.1f} MHz", file=sys.stderr)

    subdirs = [
        d for d in os.listdir(args.dir)
        if os.path.isdir(os.path.join(args.dir, d))
        and d not in ("__pycache__",)
    ]
    subdirs.sort(key=sort_key)

    labels, qps_vals, medians, p99s, p999s = [], [], [], [], []
    for name in subdirs:
        dirpath = os.path.join(args.dir, name)
        qps, median, p99, p999 = load_condition(dirpath, tsc_mhz)
        if qps is None and median is None:
            continue
        labels.append(name)
        qps_vals.append(qps / 1e3 if qps else None)   # kQPS
        medians.append(median)
        p99s.append(p99)
        p999s.append(p999)
        print(f"  {name}: QPS={qps}  median={median:.3f}µs  "
              f"p99={p99:.3f}µs  p999={p999:.3f}µs" if median else
              f"  {name}: QPS={qps}  (no samples)", file=sys.stderr)

    x = np.arange(len(labels))
    bar_color  = "#4C72B0"
    opt_color  = "#DD4444"   # N=4 強調色
    opt_idx    = next((i for i, l in enumerate(labels) if l == "N4"), None)

    fig, (ax_qps, ax_wait) = plt.subplots(
        2, 1, figsize=(10, 8),
        gridspec_kw={"height_ratios": [1, 1.3]}
    )
    fig.subplots_adjust(hspace=0.45)

    # ── 上段: QPS ──────────────────────────────────────────────
    colors = [opt_color if i == opt_idx else bar_color for i in range(len(labels))]
    bars = ax_qps.bar(x, qps_vals, color=colors, edgecolor="white", linewidth=0.5,
                      zorder=3)

    # バーの上に数値ラベル
    for bar, val in zip(bars, qps_vals):
        if val is not None:
            ax_qps.text(
                bar.get_x() + bar.get_width() / 2,
                bar.get_height() + 5,
                f"{val:.0f}k",
                ha="center", va="bottom", fontsize=7.5, color="#333333"
            )

    ax_qps.set_xticks(x)
    ax_qps.set_xticklabels(labels, fontsize=9)
    ax_qps.set_ylabel("QPS (k)", fontsize=10)
    ax_qps.set_title("QPS per N  (SPIN_ROUNDS=30)", fontsize=11)
    ax_qps.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{v:.0f}k"))
    ax_qps.set_ylim(0, max(v for v in qps_vals if v) * 1.15)
    ax_qps.grid(axis="y", linestyle="--", alpha=0.5, zorder=0)
    if opt_idx is not None:
        ax_qps.axvline(opt_idx, color=opt_color, linewidth=1.2,
                       linestyle="--", alpha=0.4)

    # ── 下段: wait time ────────────────────────────────────────
    # master は wait samples がないのでスキップしてプロット
    wait_labels, wait_x = [], []
    med_plot, p99_plot, p999_plot = [], [], []
    for i, (lbl, med, p99, p999) in enumerate(
            zip(labels, medians, p99s, p999s)):
        if med is None:
            continue
        wait_labels.append(lbl)
        wait_x.append(i)
        med_plot.append(med)
        p99_plot.append(p99)
        p999_plot.append(p999)

    # 左軸: median、右軸: p99 / p999 で独立したスケールを設ける
    ax_tail = ax_wait.twinx()

    ln_med,  = ax_wait.plot(wait_x, med_plot,  "o-", color="#2196F3", linewidth=2,
                             markersize=6, label="median (left)")
    ln_p99,  = ax_tail.plot(wait_x, p99_plot,  "s-", color="#FF9800", linewidth=2,
                             markersize=6, label="p99 (right)")
    ln_p999, = ax_tail.plot(wait_x, p999_plot, "^-", color="#F44336", linewidth=2,
                             markersize=6, label="p999 (right)")

    # 数値ラベル
    med_margin  = (max(med_plot)  - min(med_plot))  * 0.08
    tail_margin = (max(p999_plot) - min(p999_plot)) * 0.04
    for xi, med, p99, p999 in zip(wait_x, med_plot, p99_plot, p999_plot):
        ax_wait.text(xi, med - med_margin,   f"{med:.2f}", ha="center",
                     va="top",    fontsize=7.5, color="#2196F3")
        ax_tail.text(xi, p99  - tail_margin, f"{p99:.1f}", ha="center",
                     va="top",    fontsize=7.5, color="#FF9800")
        ax_tail.text(xi, p999 + tail_margin, f"{p999:.1f}", ha="center",
                     va="bottom", fontsize=7.5, color="#F44336")

    ax_wait.set_xticks(x)
    ax_wait.set_xticklabels(labels, fontsize=9)
    ax_wait.set_ylabel("median wait (µs)  [left]",  fontsize=10, color="#2196F3")
    ax_tail.set_ylabel("p99 / p999 wait (µs)  [right]", fontsize=10, color="#CC6600")
    ax_wait.tick_params(axis="y", labelcolor="#2196F3")
    ax_tail.tick_params(axis="y", labelcolor="#CC6600")
    ax_wait.set_title("Lock wait time per N  (all threads combined)", fontsize=11)

    # 余白を少し取る
    med_range  = max(med_plot)  - min(med_plot)
    tail_range = max(p999_plot) - min(p999_plot)
    ax_wait.set_ylim(min(med_plot)  - med_range  * 0.25,
                     max(med_plot)  + med_range  * 0.35)
    ax_tail.set_ylim(min(p99_plot)  - tail_range * 0.15,
                     max(p999_plot) + tail_range * 0.25)

    ax_wait.grid(axis="y", linestyle="--", alpha=0.4)
    lines = [ln_med, ln_p99, ln_p999]
    ax_wait.legend(lines, [l.get_label() for l in lines], fontsize=9, loc="upper right")
    if opt_idx is not None and opt_idx in wait_x:
        ax_wait.axvline(opt_idx, color=opt_color, linewidth=1.2,
                        linestyle="--", alpha=0.4)

    fig.suptitle(
        f"Skylake (Xeon Silver 4114)  /  SPIN_ROUNDS=30  /  TSC {tsc_mhz:.0f} MHz",
        fontsize=11, y=0.98
    )

    out = args.out or os.path.join(args.dir, "wait_summary.png")
    fig.savefig(out, dpi=150, bbox_inches="tight")
    print(f"Saved: {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
