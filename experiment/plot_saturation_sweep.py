#!/usr/bin/env python3
# Usage:
#   cd /home/morisaki/Application/memcached
#   python3 experiment/plot_saturation_sweep.py [result_dir]
#
# Parameters:
#   result_dir - 結果ディレクトリ (default: experiment/results/saturation_sweep_r1)
#
# Output:
#   {result_dir}/plots/saturation_sweep.png
#     - QPS (error bar = ±σ), write avg latency, write p99 latency
#     - 4条件を1グラフに: memcached(server)=4/8 × mutilate(client)=4/8
#
# Prerequisites:
#   pip install matplotlib pandas numpy

import sys
import os
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

RESULT_DIR = sys.argv[1] if len(sys.argv) > 1 else \
    "experiment/results/saturation_sweep_r1"
CSV_PATH = os.path.join(RESULT_DIR, "raw.csv")
PLOT_DIR = os.path.join(RESULT_DIR, "plots")
os.makedirs(PLOT_DIR, exist_ok=True)

df     = pd.read_csv(CSV_PATH)
DEPTHS = sorted(df["depth"].unique())

stats = df.groupby(["mc_threads", "mut_threads", "depth"]).agg(
    qps_mean  =("QPS",      "mean"),
    qps_std   =("QPS",      "std"),
    w_avg_mean=("w_avg_us", "mean"),
    w_p99_mean=("w_p99_us", "mean"),
).reset_index()

PALETTE = {
    (4, 4): ("#4e79a7", "o", "memcached(server)=4 / mutilate(client)=4"),
    (4, 8): ("#f28e2b", "s", "memcached(server)=4 / mutilate(client)=8"),
    (8, 4): ("#e15759", "^", "memcached(server)=8 / mutilate(client)=4"),
    (8, 8): ("#59a14f", "D", "memcached(server)=8 / mutilate(client)=8"),
}

fig, axes = plt.subplots(3, 1, figsize=(13, 15))
ax_qps, ax_avg, ax_p99 = axes

for (mc, mut), (color, marker, label) in PALETTE.items():
    d = stats[(stats.mc_threads == mc) & (stats.mut_threads == mut)].sort_values("depth")
    x = d["depth"].values

    ax_qps.errorbar(x, d["qps_mean"], yerr=d["qps_std"],
                    fmt=f"{marker}-", color=color, label=label,
                    linewidth=1.8, markersize=5, capsize=4, elinewidth=1.2)
    ax_avg.plot(x, d["w_avg_mean"], f"{marker}-", color=color, label=label,
                linewidth=1.8, markersize=5)
    ax_p99.plot(x, d["w_p99_mean"], f"{marker}-", color=color, label=label,
                linewidth=1.8, markersize=5)

def setup_xaxis(ax, log=True):
    if log:
        ax.set_xscale("log")
        ax.set_xticks(DEPTHS)
        ax.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
        ax.tick_params(axis="x", labelsize=8, rotation=45)
        ax.set_xlabel("depth (log scale)", fontsize=10)
    else:
        ax.set_xticks(DEPTHS)
        ax.tick_params(axis="x", labelsize=8, rotation=45)
        ax.set_xlabel("depth", fontsize=10)
    ax.grid(True, alpha=0.3, which="both")

def finalize(fig, axes, fname, log=True):
    ax_qps, ax_avg, ax_p99 = axes
    ax_qps.set_ylabel("QPS", fontsize=10)
    ax_qps.yaxis.set_major_formatter(
        ticker.FuncFormatter(lambda v, _: f"{v/1e3:.0f}k"))
    ax_qps.set_title("QPS  (error bar = +-sigma)", fontsize=11)
    ax_qps.set_ylim(bottom=0)
    ax_qps.legend(fontsize=9)
    setup_xaxis(ax_qps, log)

    ax_avg.set_ylabel("Latency (us)", fontsize=10)
    ax_avg.set_title("write avg latency", fontsize=11)
    ax_avg.legend(fontsize=9)
    setup_xaxis(ax_avg, log)

    ax_p99.set_ylabel("Latency (us)", fontsize=10)
    ax_p99.set_title("write p99 latency", fontsize=11)
    ax_p99.legend(fontsize=9)
    setup_xaxis(ax_p99, log)

    fig.suptitle("saturation sweep", fontsize=13)
    fig.tight_layout()
    out = os.path.join(PLOT_DIR, fname)
    fig.savefig(out, dpi=150, bbox_inches="tight")
    print(f"saved: {out}")
    plt.close(fig)

finalize(fig, axes, "saturation_sweep_log.png", log=True)

# ── linear scale ──
fig2, axes2 = plt.subplots(3, 1, figsize=(13, 15))
ax_qps2, ax_avg2, ax_p992 = axes2

for (mc, mut), (color, marker, label) in PALETTE.items():
    d = stats[(stats.mc_threads == mc) & (stats.mut_threads == mut)].sort_values("depth")
    x = d["depth"].values
    ax_qps2.errorbar(x, d["qps_mean"], yerr=d["qps_std"],
                     fmt=f"{marker}-", color=color, label=label,
                     linewidth=1.8, markersize=5, capsize=4, elinewidth=1.2)
    ax_avg2.plot(x, d["w_avg_mean"], f"{marker}-", color=color, label=label,
                 linewidth=1.8, markersize=5)
    ax_p992.plot(x, d["w_p99_mean"], f"{marker}-", color=color, label=label,
                 linewidth=1.8, markersize=5)

finalize(fig2, axes2, "saturation_sweep_linear.png", log=False)
