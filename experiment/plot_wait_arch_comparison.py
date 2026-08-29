#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_wait_arch_comparison.py
#
# Description:
#   各アーキテクチャの wait_summary.csv を読み込み、
#   pause_per_round (N) に対するロック待ち時間パーセンタイルを比較するグラフを生成する。
#   collect_results.sh で収集した結果を前提とする。
#
# Output:
#   experiment/results/wait_arch_p50.pdf   : p50 (median wait time) vs N
#   experiment/results/wait_arch_p99.pdf   : p99 wait time vs N
#   experiment/results/wait_arch_p999.pdf  : p99.9 wait time vs N
#
# Prerequisites:
#   pip install matplotlib numpy
#   experiment/results/<arch>/wait_dist_*/wait_summary.csv が存在すること

import csv
import glob
import os
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

RESULTS_BASE = "experiment/results"

ARCH_INFO = {
    "broadwell":     ("Broadwell (xl170, PAUSE~10cyc)",                "tab:blue"),
    "emeraldrapids": ("Emerald Rapids (c6620, PAUSE~22cyc)",           "tab:green"),
    "ivybridge":     ("Ivy Bridge (c8220, PAUSE~15cyc)",               "tab:red"),
    "skylake":       ("Skylake c220g5 (PAUSE~124cyc)",                 "tab:purple"),
    "skylake_ann":   ("Skylake ann (Xeon Silver 4110, PAUSE~124cyc)",  "tab:pink"),
}

COMMON_TITLE_SUFFIX = (
    "spinlock: [trylock→PAUSE×N]×30→mutex_lock / mc=4t / mut -T4 -c1 -d32 -r1 -u0.5  "
    "(median across runs)"
)


def condition_to_n(cond):
    if cond == "master":
        return -1
    m = re.match(r"N(\d+)$", cond)
    return int(m.group(1)) if m else None


def load_arch(arch_dir):
    """wait_dist_*/wait_summary.csv を全て読み込み、condition -> stats の最新値を返す。"""
    csvs = sorted(glob.glob(os.path.join(arch_dir, "wait_dist_*", "wait_summary.csv")))
    if not csvs:
        return None
    # 最新ディレクトリを使用
    latest = csvs[-1]
    data = {}
    with open(latest) as f:
        for row in csv.DictReader(f):
            n = condition_to_n(row["condition"])
            if n is None:
                continue
            data[n] = {k: float(row[k]) for k in
                       ["p50_us", "p90_us", "p95_us", "p99_us", "p999_us", "min_us"]}
    return data, latest


def load_all():
    datasets = {}
    for arch_dir in sorted(glob.glob(os.path.join(RESULTS_BASE, "*"))):
        arch = os.path.basename(arch_dir)
        if arch not in ARCH_INFO:
            continue
        result = load_arch(arch_dir)
        if result is None:
            continue
        data, path = result
        if data:
            datasets[arch] = data
            print(f"  loaded {arch}: {path} ({len(data)} conditions)")
    return datasets


def plot_metric(datasets, metric, ylabel, title_prefix, out_path):
    fig, ax = plt.subplots(figsize=(10, 6))

    for arch, data in datasets.items():
        disp, color = ARCH_INFO.get(arch, (arch, None))
        points = sorted((n, v[metric]) for n, v in data.items() if n >= 0)
        if not points:
            continue
        xs, ys = zip(*points)
        ax.plot(xs, ys, marker="o", markersize=5, linewidth=1.8,
                color=color, label=disp)
        if -1 in data:
            ax.axhline(data[-1][metric], color=color,
                       linestyle="--", linewidth=0.8, alpha=0.45)

    ax.set_xlabel("pause_per_round (N)", fontsize=12)
    ax.set_ylabel(f"{ylabel} (µs)", fontsize=12)
    ax.set_title(f"{title_prefix} vs pause_per_round\n{COMMON_TITLE_SUFFIX}", fontsize=10)
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    ax.set_xlim(left=-2)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  saved: {out_path}")


if __name__ == "__main__":
    print("Loading wait_summary.csv ...")
    datasets = load_all()

    if not datasets:
        print("[ERROR] No wait_summary.csv found.")
        print("  collect_results.sh を実行してから再試行してください。")
        exit(1)

    print(f"\nGenerating plots ({len(datasets)} arch(es)) ...")

    plot_metric(datasets, "p50_us",  "Lock wait p50",  "Lock wait p50",
                os.path.join(RESULTS_BASE, "wait_arch_p50.pdf"))
    plot_metric(datasets, "p99_us",  "Lock wait p99",  "Lock wait p99",
                os.path.join(RESULTS_BASE, "wait_arch_p99.pdf"))
    plot_metric(datasets, "p999_us", "Lock wait p99.9", "Lock wait p99.9",
                os.path.join(RESULTS_BASE, "wait_arch_p999.pdf"))

    print("\nDone.")
