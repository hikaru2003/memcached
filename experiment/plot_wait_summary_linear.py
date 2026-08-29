#!/usr/bin/env python3
# Usage:
#   python3 experiment/plot_wait_summary_linear.py \
#       --dir experiment/results/wait_dist_YYYYMMDD_HHMMSS \
#       [--tsc-mhz MHZ] [--out PATH]
#
# Parameters:
#   --dir DIR      wait_dist 実験結果ディレクトリ
#   --tsc-mhz MHZ TSC周波数 MHz（省略で /proc/cpuinfo から自動取得）
#   --out PATH     出力画像パス（省略で <DIR>/wait_summary_linear.pdf）
#
# Output:
#   wait_summary_linear.pdf — wait_summary.pdf と同内容だが横軸を N の実際の値に揃えたグラフ
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


def load_condition(dirpath, tsc_mhz):
    qps = None
    stats_path = os.path.join(dirpath, "stats.txt")
    if os.path.exists(stats_path):
        for line in open(stats_path):
            m = re.search(r"mean_qps=(\d+)", line)
            if m:
                qps = int(m.group(1))

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

    # N値の条件を収集
    n_entries = []
    for name in os.listdir(args.dir):
        if not os.path.isdir(os.path.join(args.dir, name)):
            continue
        if name == "master":
            continue
        m = re.match(r"N(\d+)$", name)
        if not m:
            continue
        n_val = int(m.group(1))
        dirpath = os.path.join(args.dir, name)
        qps, median, p99, p999 = load_condition(dirpath, tsc_mhz)
        if qps is None:
            continue
        n_entries.append((n_val, name, qps, median, p99, p999))
        print(f"  {name} (N={n_val}): QPS={qps}  "
              + (f"median={median:.3f}µs  p99={p99:.3f}µs  p999={p999:.3f}µs"
                 if median else "(no samples)"), file=sys.stderr)

    n_entries.sort(key=lambda e: e[0])

    # master
    master_dir = os.path.join(args.dir, "master")
    master_qps = None
    if os.path.isdir(master_dir):
        master_qps, _, _, _ = load_condition(master_dir, tsc_mhz)
        print(f"  master: QPS={master_qps}", file=sys.stderr)

    xs      = [e[0] for e in n_entries]          # 実際のN値
    qps_k   = [e[2] / 1e3 for e in n_entries]
    medians = [e[3] for e in n_entries]
    p99s    = [e[4] for e in n_entries]
    p999s   = [e[5] for e in n_entries]

    OPT_N     = 4
    OPT_COLOR = "#DD4444"
    BAR_COLOR = "#4C72B0"

    fig, (ax_qps, ax_wait) = plt.subplots(
        2, 1, figsize=(10, 8),
        gridspec_kw={"height_ratios": [1, 1.3]}
    )
    fig.subplots_adjust(hspace=0.45)

    # ── 上段: QPS ライン ────────────────────────────────────────
    point_colors = [OPT_COLOR if e[0] == OPT_N else BAR_COLOR for e in n_entries]

    ax_qps.plot(xs, qps_k, color=BAR_COLOR, linewidth=1.5, zorder=2)
    for xi, yi, c in zip(xs, qps_k, point_colors):
        ax_qps.scatter(xi, yi, color=c, s=60, zorder=3)
        ax_qps.text(xi, yi + max(qps_k) * 0.02, f"{yi:.0f}k",
                    ha="center", va="bottom", fontsize=7.5, color="#333333")

    if master_qps is not None:
        mq = master_qps / 1e3
        ax_qps.axhline(mq, color="gray", linestyle="--", linewidth=1.2,
                       label=f"master = {mq:.0f}k", zorder=1)
        ax_qps.text(max(xs) * 1.01, mq, f"{mq:.0f}k",
                    va="center", fontsize=8, color="gray")

    ax_qps.axvline(OPT_N, color=OPT_COLOR, linewidth=1.2, linestyle="--", alpha=0.4)
    ax_qps.set_xlabel("pause_per_round (N)", fontsize=10)
    ax_qps.set_ylabel("QPS (k)", fontsize=10)
    ax_qps.set_title("QPS per N  (SPIN_ROUNDS=30)", fontsize=11)
    ax_qps.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{v:.0f}k"))
    ax_qps.set_ylim(0, max(qps_k) * 1.15)
    ax_qps.set_xlim(-5, max(xs) * 1.05)
    ax_qps.set_xticks(xs)
    ax_qps.grid(axis="y", linestyle="--", alpha=0.5, zorder=0)
    if master_qps:
        ax_qps.legend(fontsize=9, loc="lower right")

    # ── 下段: wait time ────────────────────────────────────────
    wait_mask = [m is not None for m in medians]
    wx    = [xs[i]      for i, ok in enumerate(wait_mask) if ok]
    wmed  = [medians[i] for i, ok in enumerate(wait_mask) if ok]
    wp99  = [p99s[i]    for i, ok in enumerate(wait_mask) if ok]
    wp999 = [p999s[i]   for i, ok in enumerate(wait_mask) if ok]

    ax_tail = ax_wait.twinx()

    ln_med,  = ax_wait.plot(wx, wmed,  "o-", color="#2196F3", linewidth=2,
                             markersize=6, label="median (left)")
    ln_p99,  = ax_tail.plot(wx, wp99,  "s-", color="#FF9800", linewidth=2,
                             markersize=6, label="p99 (right)")
    ln_p999, = ax_tail.plot(wx, wp999, "^-", color="#F44336", linewidth=2,
                             markersize=6, label="p999 (right)")

    med_margin  = (max(wmed)  - min(wmed))  * 0.08 + 1e-6
    tail_margin = (max(wp999) - min(wp999)) * 0.04 + 1e-6
    for xi, med, p99, p999 in zip(wx, wmed, wp99, wp999):
        ax_wait.text(xi, med  - med_margin,  f"{med:.2f}",  ha="center",
                     va="top",    fontsize=7.5, color="#2196F3")
        ax_tail.text(xi, p99  - tail_margin, f"{p99:.1f}",  ha="center",
                     va="top",    fontsize=7.5, color="#FF9800")
        ax_tail.text(xi, p999 + tail_margin, f"{p999:.1f}", ha="center",
                     va="bottom", fontsize=7.5, color="#F44336")

    ax_wait.axvline(OPT_N, color=OPT_COLOR, linewidth=1.2, linestyle="--", alpha=0.4)
    ax_wait.set_xlabel("pause_per_round (N)", fontsize=10)
    ax_wait.set_ylabel("median wait (µs)  [left]",      fontsize=10, color="#2196F3")
    ax_tail.set_ylabel("p99 / p999 wait (µs)  [right]", fontsize=10, color="#CC6600")
    ax_wait.tick_params(axis="y", labelcolor="#2196F3")
    ax_tail.tick_params(axis="y", labelcolor="#CC6600")
    ax_wait.set_title("Lock wait time per N  (all threads combined)", fontsize=11)
    ax_wait.set_xlim(-5, max(xs) * 1.05)
    ax_wait.set_xticks(xs)

    med_range  = max(wmed)  - min(wmed)
    tail_range = max(wp999) - min(wp999)
    ax_wait.set_ylim(min(wmed)  - med_range  * 0.25, max(wmed)  + med_range  * 0.35)
    ax_tail.set_ylim(min(wp99)  - tail_range * 0.15, max(wp999) + tail_range * 0.25)

    ax_wait.grid(axis="y", linestyle="--", alpha=0.4)
    lines = [ln_med, ln_p99, ln_p999]
    ax_wait.legend(lines, [l.get_label() for l in lines], fontsize=9, loc="upper right")

    fig.suptitle(
        f"Skylake (Xeon Silver 4114)  /  SPIN_ROUNDS=30  /  TSC {tsc_mhz:.0f} MHz\n"
        "(x-axis: actual N value)",
        fontsize=11, y=0.98
    )

    out = args.out or os.path.join(args.dir, "wait_summary_linear.pdf")
    fig.savefig(out, dpi=150, bbox_inches="tight")
    print(f"Saved: {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
