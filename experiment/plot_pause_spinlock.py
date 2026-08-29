#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_pause_spinlock.py
#
# Description:
#   pause-spinlock ブランチ（Skylake ann サーバ）の sweep 結果を出力する。
#   対象ブランチ: experiment/pause-spinlock
#   実装: [trylock → PAUSE×1] × N → mutex_lock  （N = PAUSE_COUNT）
#   データソース: experiment/results/pause_spinlock_skylake_ann/raw.csv
#     （pause-spinlock ブランチの pause_d32_mc4_mut4_run3/get50_set50/raw.csv から抽出）
#
# Output:
#   experiment/results/pause_spinlock_skylake_ann_qps.pdf : 生QPS ± 1σ
#
# Prerequisites:
#   pip install matplotlib numpy
#   experiment/results/pause_spinlock_skylake_ann/raw.csv が存在すること
#   （存在しない場合: git show experiment/pause-spinlock:experiment/results/
#     pause_d32_mc4_mut4_run3/get50_set50/raw.csv > 上記パス で抽出）

import csv
import os
import re
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

RESULTS_BASE  = "experiment/results"
DATA_DIR      = os.path.join(RESULTS_BASE, "pause_spinlock_skylake_ann")
OUT_QPS       = os.path.join(RESULTS_BASE, "pause_spinlock_skylake_ann_qps.pdf")

TITLE_SUFFIX  = (
    "spinlock: [trylock → PAUSE×1] × N → mutex_lock\n"
    "Skylake ann (Xeon Silver 4114, PAUSE~142cyc) / "
    "mc=4t / mut -T4 -c1 -d32 -r1 -u0.5 / n=10"
)
COLOR = "tab:pink"


def parse_raw_csv(path):
    data = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            label = row["label"]
            if label not in data:
                data[label] = {"qps": [], "r_avg": [], "r_p99": []}
            try:
                data[label]["qps"].append(float(row["QPS"]))
                data[label]["r_avg"].append(float(row["r_avg_us"]))
                data[label]["r_p99"].append(float(row["r_p99_us"]))
            except (ValueError, KeyError):
                pass
    return data


def main():
    csv_path = os.path.join(DATA_DIR, "raw.csv")
    if not os.path.exists(csv_path):
        print(f"[ERROR] {csv_path} not found")
        return

    raw = parse_raw_csv(csv_path)

    points = []
    master_qps = None
    for label, vals in raw.items():
        if label == "master_baseline":
            master_qps = np.mean(vals["qps"])
            continue
        m = re.match(r'pause_(\d+)', label)
        if not m:
            continue
        n = int(m.group(1))
        mean_qps = np.mean(vals["qps"])
        sd_qps   = np.std(vals["qps"], ddof=1) if len(vals["qps"]) > 1 else 0
        points.append((n, mean_qps, sd_qps))
        print(f"  N={n:4d}: QPS={mean_qps/1e3:.1f}k ± {sd_qps/1e3:.1f}k")

    points.sort()
    xs  = [p[0] for p in points]
    ys  = [p[1] / 1000 for p in points]
    es  = [p[2] / 1000 for p in points]

    fig, ax = plt.subplots(figsize=(11, 6))
    ax.errorbar(xs, ys, yerr=es, label="Skylake ann (pause-spinlock)",
                color=COLOR, marker='o', markersize=4, linewidth=1.5,
                capsize=3, elinewidth=1.0)
    if master_qps is not None:
        ax.axhline(master_qps / 1000, color=COLOR, linestyle='--',
                   linewidth=0.8, alpha=0.6,
                   label=f"master baseline ({master_qps/1e3:.1f}k)")
        print(f"  master: QPS={master_qps/1e3:.1f}k")

    ax.set_xlabel("PAUSE_COUNT (N)", fontsize=12)
    ax.set_ylabel("Mean QPS (kQPS)  ±1σ", fontsize=12)
    ax.set_title(f"QPS vs PAUSE_COUNT (error bars = ±1σ)\n{TITLE_SUFFIX}", fontsize=10)
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    ax.set_xlim(left=-10)
    fig.tight_layout()
    fig.savefig(OUT_QPS, dpi=150)
    plt.close(fig)
    print(f"  saved: {OUT_QPS}")


if __name__ == "__main__":
    main()
