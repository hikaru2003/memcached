#!/usr/bin/env python3
# Usage: python3 experiment/plot_cdf_comparison.py [--data-dir DIR] [--output OUT] [--labels N ...]
# パラメータ:
#   --data-dir: raw/*.log を含むディレクトリ
#               (default: experiment/results/skylake/utdelay_sweep_c220g5_skylake/raw)
#   --output:   出力ファイルパス (default: experiment/results/cdf_latency_skylake.png)
#   --labels:   比較するN値のリスト (default: master 0 4 10 100 200)
# 出力先: experiment/results/cdf_latency_skylake.png
# 前提条件: matplotlib, numpy がインストール済み
#           mutilate logファイルが raw/ 以下に run_N{N}_{run}.log / run_master_{run}.log で存在すること

import re
import sys
import glob
import argparse
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from pathlib import Path

# read行のカラム (vals = line.split()[1:] のインデックス)
# avg(0) std(1) min(2) 5th(3) 10th(4) 90th(5) 95th(6) 99th(7)
PERCENTILE_COLS = [
    (0.05, 3, "p5"),
    (0.10, 4, "p10"),
    (0.50, 0, "avg"),     # avgをp50の近似として使用（注: 平均≠中央値だが参考として）
    (0.90, 5, "p90"),
    (0.95, 6, "p95"),
    (0.99, 7, "p99"),
]

YTICKS      = [cdf for cdf, _, _ in PERCENTILE_COLS]
YTICK_LABELS = [name for _, _, name in PERCENTILE_COLS]


def parse_log(path):
    """mutilate logファイルからread行のパーセンタイル値を抽出"""
    with open(path) as f:
        for line in f:
            if line.startswith("read"):
                vals = line.split()
                return [float(v) for v in vals[1:]]
    return None


def load_data(raw_dir, labels):
    """各N値ごとに複数ランの平均パーセンタイル値を返す"""
    data = {}
    for label in labels:
        if label == "master":
            pattern = str(Path(raw_dir) / "run_master_*.log")
        else:
            pattern = str(Path(raw_dir) / f"run_N{label}_*.log")

        files = sorted(glob.glob(pattern))
        if not files:
            print(f"Warning: no files found for label={label!r} ({pattern})", file=sys.stderr)
            continue

        runs = []
        for f in files:
            vals = parse_log(f)
            if vals is not None:
                runs.append(vals)

        if runs:
            data[label] = np.mean(runs, axis=0)
        else:
            print(f"Warning: could not parse any log for label={label!r}", file=sys.stderr)

    return data


def plot_cdf(data, labels, output_path, title=None):
    fig, ax = plt.subplots(figsize=(10, 6))

    cmap = plt.cm.tab10
    colors = [cmap(i / max(len(labels) - 1, 1)) for i in range(len(labels))]

    for label, color in zip(labels, colors):
        if label not in data:
            continue

        vals = data[label]
        lat_pts = [vals[col_idx] for _, col_idx, _ in PERCENTILE_COLS]
        cdf_pts = [cdf for cdf, _, _ in PERCENTILE_COLS]

        display = "master (baseline)" if label == "master" else f"N={label}"
        linestyle = "--" if label == "master" else "-"
        ax.plot(lat_pts, cdf_pts,
                marker="o", markersize=5,
                label=display, color=color, linestyle=linestyle, linewidth=1.5)

    ax.set_xscale("log")
    xticks = [100, 110, 120, 130, 140, 150, 160, 180, 200, 220, 250, 300, 350]
    ax.set_xticks(xticks)
    ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
    ax.xaxis.set_minor_locator(ticker.NullLocator())
    plt.setp(ax.get_xticklabels(), rotation=45, ha="right", fontsize=9)
    ax.set_xlabel("Read Latency (μs)", fontsize=12)
    ax.set_ylabel("CDF", fontsize=12)
    default_title = (
        "Read Latency CDF by PAUSE count N\n"
        "Skylake (c220g5 / Xeon Silver 4114), SPIN_ROUNDS=30, 20 runs avg"
    )
    ax.set_title(title if title else default_title, fontsize=12)

    ax.set_yticks(YTICKS)
    ax.set_yticklabels(YTICK_LABELS, fontsize=10)
    ax.set_ylim(0, 1.05)

    # 主要パーセンタイルに水平点線
    for cdf_val, _, name in PERCENTILE_COLS:
        ax.axhline(cdf_val, color="gray", linewidth=0.4, linestyle=":")

    ax.legend(loc="lower right", fontsize=10)
    ax.grid(True, which="both", alpha=0.25)

    # avgをp50近似として使っている旨の注記
    ax.annotate(
        "* avg used as p50 approximation",
        xy=(0.01, 0.02), xycoords="axes fraction",
        fontsize=8, color="gray"
    )

    plt.tight_layout()
    plt.savefig(output_path, dpi=150, bbox_inches="tight")
    print(f"Saved: {output_path}")
    plt.close()


def main():
    parser = argparse.ArgumentParser(
        description="Plot approximate CDF of read latency from mutilate log files"
    )
    parser.add_argument(
        "--data-dir",
        default="experiment/results/skylake/utdelay_sweep_c220g5_skylake/raw",
        help="Directory containing raw/*.log files"
    )
    parser.add_argument(
        "--output",
        default="experiment/results/cdf_latency_skylake.png",
        help="Output PNG path"
    )
    parser.add_argument(
        "--labels",
        nargs="+",
        default=["master", "0", "4", "10", "100", "200"],
        help="N values to compare (use 'master' for baseline)"
    )
    parser.add_argument(
        "--title",
        default=None,
        help="Graph title (2 lines separated by \\n)"
    )
    args = parser.parse_args()

    data = load_data(args.data_dir, args.labels)
    if not data:
        print("Error: no data loaded", file=sys.stderr)
        sys.exit(1)

    plot_cdf(data, args.labels, args.output, title=args.title)


if __name__ == "__main__":
    main()
