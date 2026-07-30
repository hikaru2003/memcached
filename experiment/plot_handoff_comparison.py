#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_handoff_comparison.py
#   OUTPUT_DIR=experiment/results/plots/v3 python3 experiment/plot_handoff_comparison.py
#
# Description:
#   Broadwell / Skylake ann の handoff latency sweep 結果を可視化する。
#   ロックハンドオフレイテンシ（unlock → 次スレッドの acquire 完了までの時間）の
#   パーセンタイル分布を PAUSE count N の関数としてプロットする。
#
#   生成グラフ:
#   1. handoff_p50_p99.pdf  — p50 / p99 vs N（2アーキ比較）
#   2. handoff_cdf.pdf      — 代表N値のCDF（per-arch, 2 subplots）
#
# Parameters (env vars):
#   OUTPUT_DIR - 出力先ディレクトリ (default: experiment/results/plots/v2)
#
# Output:
#   $OUTPUT_DIR/handoff_p50_p99.pdf
#   $OUTPUT_DIR/handoff_cdf.pdf
#
# Prerequisites:
#   pip install matplotlib numpy
#   experiment/results/broadwell/handoff_*/handoff_summary.csv
#   experiment/results/handoff_*/handoff_summary.csv  (Skylake ann, toplevel)

import csv
import glob
import os
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

RESULTS_BASE = "experiment/results"
OUTPUT_DIR   = os.environ.get("OUTPUT_DIR", os.path.join(RESULTS_BASE, "plots", "v2"))
os.makedirs(OUTPUT_DIR, exist_ok=True)

ARCH_INFO = {
    "broadwell":   {"label": "Broadwell (xl170, PAUSE~12cyc)",          "color": "tab:blue"},
    "skylake_ann": {"label": "Skylake ann (Silver 4114, PAUSE~142cyc)", "color": "tab:green"},
}

# handoff_summary.csv を検索（最新）
def find_handoff_csv(arch):
    if arch == "broadwell":
        cands = sorted(glob.glob(os.path.join(RESULTS_BASE, "broadwell", "handoff_*", "handoff_summary.csv")))
    else:
        cands = sorted(
            p for p in glob.glob(os.path.join(RESULTS_BASE, "handoff_*", "handoff_summary.csv"))
            if "broadwell" not in p
        )
    return cands[-1] if cands else None


def parse_summary(path):
    rows = []
    with open(path) as f:
        for row in csv.DictReader(f):
            m = re.match(r"N(\d+)$", row["condition"])
            if not m:
                continue
            n = int(m.group(1))
            rows.append({
                "n":       n,
                "p50_us":  float(row["p50_us"]),
                "p99_us":  float(row["p99_us"]),
                "p999_us": float(row["p999_us"]),
            })
    rows.sort(key=lambda r: r["n"])
    return rows


def load_all():
    datasets = {}
    for arch in ARCH_INFO:
        path = find_handoff_csv(arch)
        if path is None:
            print(f"[WARN] {arch}: handoff_summary.csv not found")
            continue
        print(f"[INFO] {arch}: {path}")
        rows = parse_summary(path)
        datasets[arch] = rows
    return datasets


def setup_fig(w=7, h=4.5):
    fig, ax = plt.subplots(figsize=(w, h))
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    return fig, ax


def save(fig, name):
    path = os.path.join(OUTPUT_DIR, name)
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved: {path}")


# -------------------------------------------------------------------
# Plot 1: p50 / p99 vs N（2アーキ比較、2 subplots）
# -------------------------------------------------------------------

def plot_p50_p99(datasets):
    fig, (ax_p50, ax_p99) = plt.subplots(1, 2, figsize=(12, 4.5))
    for ax in (ax_p50, ax_p99):
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)

    for arch, info in ARCH_INFO.items():
        if arch not in datasets:
            continue
        rows = datasets[arch]
        ns   = [r["n"]      for r in rows]
        p50  = [r["p50_us"] for r in rows]
        p99  = [r["p99_us"] for r in rows]
        ax_p50.plot(ns, p50, label=info["label"], color=info["color"],
                    marker="o", markersize=3, linewidth=1.2)
        ax_p99.plot(ns, p99, label=info["label"], color=info["color"],
                    marker="o", markersize=3, linewidth=1.2)

    ax_p50.set_xlabel("pause_per_round (N)")
    ax_p50.set_ylabel("handoff latency (µs)")
    ax_p50.set_title("p50 handoff latency vs PAUSE count")
    ax_p50.legend(fontsize=9)
    ax_p50.grid(axis="y", linestyle=":", alpha=0.4)

    ax_p99.set_xlabel("pause_per_round (N)")
    ax_p99.set_ylabel("handoff latency (µs)")
    ax_p99.set_title("p99 handoff latency vs PAUSE count")
    ax_p99.legend(fontsize=9)
    ax_p99.grid(axis="y", linestyle=":", alpha=0.4)

    fig.tight_layout()
    save(fig, "handoff_p50_p99.pdf")


# -------------------------------------------------------------------
# Plot 2: p50 / p99 / p999 3線 vs N（1グラフに全パーセンタイル, per-arch）
# -------------------------------------------------------------------

def plot_percentiles_overlay(datasets):
    archs = [a for a in ARCH_INFO if a in datasets]
    if not archs:
        return

    fig, axes = plt.subplots(1, len(archs), figsize=(6 * len(archs), 4.5))
    if len(archs) == 1:
        axes = [axes]

    for ax, arch in zip(axes, archs):
        info = ARCH_INFO[arch]
        rows = datasets[arch]
        ns   = [r["n"]       for r in rows]
        p50  = [r["p50_us"]  for r in rows]
        p99  = [r["p99_us"]  for r in rows]
        p999 = [r["p999_us"] for r in rows]

        ax.plot(ns, p50,  marker="o", markersize=2, linewidth=1.2,
                label="p50", color="tab:blue")
        ax.plot(ns, p99,  marker="s", markersize=2, linewidth=1.2,
                label="p99", color="tab:orange")
        ax.plot(ns, p999, marker="^", markersize=2, linewidth=1.2,
                label="p999", color="tab:red")

        ax.set_xlabel("pause_per_round (N)")
        ax.set_ylabel("handoff latency (µs)")
        ax.set_title(info["label"], fontsize=9)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        ax.legend(fontsize=9)
        ax.grid(axis="y", linestyle=":", alpha=0.4)

    fig.suptitle("Lock Hand-off Latency vs PAUSE count", fontsize=11, y=1.01)
    fig.tight_layout()
    save(fig, "handoff_percentiles.pdf")


# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------

if __name__ == "__main__":
    datasets = load_all()
    if not datasets:
        print("[ERROR] No data found. Run handoff sweep first.")
        raise SystemExit(1)

    plot_p50_p99(datasets)
    plot_percentiles_overlay(datasets)

    print(f"\nDone. PDFs saved to: {OUTPUT_DIR}")
