#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_handoff_comparison.py
#   OUTPUT_DIR=experiment/results/plots/v3 python3 experiment/plot_handoff_comparison.py
#
# Description:
#   Broadwell / Emerald Rapids / Ice Lake / Skylake ann の handoff latency sweep 結果を可視化する。
#   ロックハンドオフレイテンシ（unlock → 次スレッドの acquire 完了までの時間）の
#   パーセンタイル分布を PAUSE count N の関数としてプロットする。
#
#   生成グラフ:
#   1. handoff_p50_p99.pdf      — p50 / p99 vs N（アーキ比較、2 subplots）
#   2. handoff_percentiles.pdf  — p50 / p99 / p99.9 vs N（per-arch subplots）
#
# Parameters (env vars):
#   OUTPUT_DIR - 出力先ディレクトリ (default: experiment/results/plots/v2)
#
# Output:
#   $OUTPUT_DIR/handoff_p50_p99.pdf
#   $OUTPUT_DIR/handoff_percentiles.pdf
#
# Prerequisites:
#   pip install matplotlib numpy scipy
#   experiment/results/<arch>/handoff_*/handoff_summary.csv

import csv
import glob
import os
import re

import matplotlib
matplotlib.use("Agg")
matplotlib.rcParams["font.family"]        = "Noto Sans CJK JP"
matplotlib.rcParams["axes.unicode_minus"] = False
import matplotlib.pyplot as plt
import numpy as np
from scipy.interpolate import PchipInterpolator

RESULTS_BASE = "experiment/results"
OUTPUT_DIR   = os.environ.get("OUTPUT_DIR", os.path.join(RESULTS_BASE, "plots", "v2"))
os.makedirs(OUTPUT_DIR, exist_ok=True)

ARCH_INFO = {
    "broadwell":     {"label": "Broadwell (PAUSE~10cyc)",      "color": "tab:blue"},
    "emeraldrapids": {"label": "Emerald Rapids (PAUSE~22cyc)", "color": "tab:red"},
    "icelake":       {"label": "Sunny Cove (PAUSE~39cyc)",     "color": "tab:orange"},
    "skylake_ann":   {"label": "Skylake (PAUSE~124cyc)",       "color": "tab:green"},
}

# handoff_summary.csv を検索（最新）
def find_handoff_csv(arch):
    cands = sorted(glob.glob(
        os.path.join(RESULTS_BASE, arch, "handoff_*", "handoff_summary.csv")
    ))
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
# Plot 1: p50 / p99 vs N（アーキ比較、2 subplots）
# -------------------------------------------------------------------

def plot_p50_p99(datasets):
    fig, (ax_p50, ax_p99) = plt.subplots(1, 2, figsize=(14, 5))
    for ax in (ax_p50, ax_p99):
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)

    for arch, info in ARCH_INFO.items():
        if arch not in datasets:
            continue
        rows = datasets[arch]
        ns  = np.array([r["n"]      for r in rows], dtype=float)
        p50 = np.array([r["p50_us"] for r in rows], dtype=float)
        p99 = np.array([r["p99_us"] for r in rows], dtype=float)
        xs  = np.linspace(ns[0], ns[-1], 500)

        ax_p50.plot(xs, PchipInterpolator(ns, p50)(xs),
                    color=info["color"], linewidth=1.5, label=info["label"])
        ax_p50.scatter(ns, p50, color=info["color"], s=14, zorder=5)

        ax_p99.plot(xs, PchipInterpolator(ns, p99)(xs),
                    color=info["color"], linewidth=1.5, label=info["label"])
        ax_p99.scatter(ns, p99, color=info["color"], s=14, zorder=5)

    for ax, title, ylabel in [
        (ax_p50, "p50 ハンドオフレイテンシ", "ハンドオフレイテンシ [µs]"),
        (ax_p99, "p99 ハンドオフレイテンシ", "ハンドオフレイテンシ [µs]"),
    ]:
        ax.set_xlabel("PAUSE 実行回数/スピン", fontsize=12)
        ax.set_ylabel(ylabel, fontsize=12)
        ax.set_title(title, fontsize=13)
        ax.legend(fontsize=10)
        ax.grid(axis="y", linestyle=":", alpha=0.4)

    fig.tight_layout()
    save(fig, "handoff_p50_p99.pdf")


# -------------------------------------------------------------------
# Plot 2: p50 / p99 / p99.9 vs N（per-arch subplots, 左軸p50 / 右軸p99+p99.9）
# -------------------------------------------------------------------

def plot_percentiles_overlay(datasets):
    archs = [a for a in ARCH_INFO if a in datasets]
    if not archs:
        return

    ncols = len(archs)
    fig, axes = plt.subplots(1, ncols, figsize=(6 * ncols, 5))
    if ncols == 1:
        axes = [axes]

    for ax_l, arch in zip(axes, archs):
        info = ARCH_INFO[arch]
        rows = datasets[arch]
        ns   = np.array([r["n"]       for r in rows], dtype=float)
        p50  = np.array([r["p50_us"]  for r in rows], dtype=float)
        p99  = np.array([r["p99_us"]  for r in rows], dtype=float)
        p999 = np.array([r["p999_us"] for r in rows], dtype=float)
        xs   = np.linspace(ns[0], ns[-1], 500)

        ax_r = ax_l.twinx()

        l1, = ax_l.plot(xs, PchipInterpolator(ns, p50)(xs),
                        color="tab:blue", linewidth=1.5, label="p50 (左軸)")
        ax_l.scatter(ns, p50, color="tab:blue", s=16, zorder=5, marker="o")

        l2, = ax_r.plot(xs, PchipInterpolator(ns, p99)(xs),
                        color="tab:orange", linewidth=1.5, label="p99 (右軸)")
        ax_r.scatter(ns, p99, color="tab:orange", s=16, zorder=5, marker="s")

        l3, = ax_r.plot(xs, PchipInterpolator(ns, p999)(xs),
                        color="tab:red", linewidth=1.5, label="p99.9 (右軸)")
        ax_r.scatter(ns, p999, color="tab:red", s=16, zorder=5, marker="^")

        ax_l.set_xlabel("PAUSE 実行回数/スピン", fontsize=11)
        ax_l.set_ylabel("p50 ハンドオフレイテンシ [µs]", color="tab:blue", fontsize=11)
        ax_r.set_ylabel("p99 / p99.9 ハンドオフレイテンシ [µs]", color="tab:red", fontsize=11)
        ax_l.tick_params(axis="y", labelcolor="tab:blue")
        ax_r.tick_params(axis="y", labelcolor="tab:red")
        ax_l.set_title(info["label"], fontsize=11)
        ax_l.spines["top"].set_visible(False)
        ax_l.grid(axis="y", linestyle=":", alpha=0.4)
        ax_l.legend([l1, l2, l3], [l.get_label() for l in [l1, l2, l3]],
                    fontsize=10, loc="upper right")

    fig.suptitle("ロックハンドオフレイテンシ vs PAUSE 実行回数", fontsize=13, y=1.02)
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
