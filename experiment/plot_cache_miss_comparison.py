#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_cache_miss_comparison.py
#   OUTPUT_DIR=experiment/results/plots/v3 python3 experiment/plot_cache_miss_comparison.py
#
# Description:
#   Broadwell / Ice Lake / Skylake ann の cache miss sweep 実験結果を可視化する。
#   bus contention (demand_rfo) と QPS/レイテンシの関係を示す4種のグラフを生成する。
#   1. QPS vs N                              — 3アーキ比較, エラーバー=±1σ
#   2. demand_rfo/req vs N                   — bus contention指標, 3アーキ比較
#   3. QPS + demand_rfo/req 二軸グラフ       — per-arch 3 subplots
#   4. p999 latency vs N                     — 3アーキ比較
#
# Parameters (env vars):
#   OUTPUT_DIR - 出力先ディレクトリ (default: experiment/results/plots/v2)
#
# Output:
#   $OUTPUT_DIR/cache_miss_qps.pdf
#   $OUTPUT_DIR/cache_miss_demand_rfo.pdf
#   $OUTPUT_DIR/cache_miss_qps_rfo_overlay.pdf
#   $OUTPUT_DIR/cache_miss_p999.pdf
#
# Prerequisites:
#   pip install matplotlib numpy
#   experiment/results/broadwell/cache_miss_*/summary.csv   (Broadwell)
#   experiment/results/icelake/cache_miss_*/summary.csv     (Ice Lake)
#   experiment/results/skylake_ann/cache_miss_*/summary.csv (Skylake ann)

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

RESULTS_BASE = "experiment/results"
OUTPUT_DIR   = os.environ.get("OUTPUT_DIR", os.path.join(RESULTS_BASE, "plots", "v2"))
os.makedirs(OUTPUT_DIR, exist_ok=True)

DURATION_SEC = 60  # perf stat / mutilate 計測ウィンドウ (秒)

ARCH_INFO = {
    "broadwell":   {"label": "Broadwell   E5-2640v4  PAUSE~10cy  L3=25MB/socket", "color": "tab:blue"},
    "icelake":     {"label": "Sunny Cove  Silver4314 PAUSE~39cy  L3=24MB/socket", "color": "tab:orange"},
    "skylake_ann": {"label": "Skylake     Silver4110 PAUSE~124cy L3=11MB",        "color": "tab:green"},
}

def find_cache_miss_csv(arch):
    cands = sorted(glob.glob(os.path.join(RESULTS_BASE, arch, "cache_miss_*", "summary.csv")))
    return cands[-1] if cands else None


def parse_summary(path):
    """summary.csv → {label: {"qps":[], "p99":[], "p999":[], "demand_rfo":[], "cache_ref":[]}}"""
    data = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            label = row["label"]
            if label not in data:
                data[label] = {"qps": [], "p99": [], "p999": [], "demand_rfo": [], "cache_ref": []}
            try:
                data[label]["qps"].append(float(row["QPS"]))
                data[label]["p99"].append(float(row["r_p99_us"]))
                data[label]["p999"].append(float(row["r_p999_us"]))
                data[label]["demand_rfo"].append(float(row["demand_rfo"]))
                data[label]["cache_ref"].append(float(row["cache_references"]))
            except (ValueError, KeyError):
                pass
    return data


def aggregate(data):
    """各ラベルについて mean / std を計算し、N値でソートして返す"""
    rows = []
    master_qps = None
    for label, vals in data.items():
        if label == "master":
            n = -1
        else:
            m = re.match(r"N(\d+)$", label)
            if not m:
                continue
            n = int(m.group(1))
        qps_mean  = np.mean(vals["qps"])
        qps_std   = np.std(vals["qps"], ddof=1) if len(vals["qps"]) > 1 else 0.0
        p99_mean  = np.mean(vals["p99"])
        p99_std   = np.std(vals["p99"],  ddof=1) if len(vals["p99"]) > 1 else 0.0
        p999_mean = np.mean(vals["p999"])
        p999_std  = np.std(vals["p999"], ddof=1) if len(vals["p999"]) > 1 else 0.0

        drfo      = np.mean(vals["demand_rfo"])
        drfo_std  = np.std(vals["demand_rfo"], ddof=1) if len(vals["demand_rfo"]) > 1 else 0.0
        rfo_per_req     = drfo     / (qps_mean  * DURATION_SEC)
        rfo_per_req_std = drfo_std / (qps_mean  * DURATION_SEC)

        if label == "master":
            master_qps = qps_mean

        rows.append({
            "label": label, "n": n,
            "qps_mean": qps_mean, "qps_std": qps_std,
            "p99_mean": p99_mean, "p99_std": p99_std,
            "p999_mean": p999_mean, "p999_std": p999_std,
            "rfo_per_req": rfo_per_req, "rfo_per_req_std": rfo_per_req_std,
        })

    rows.sort(key=lambda r: r["n"])
    return rows, master_qps


def load_all():
    datasets = {}
    for arch in ARCH_INFO:
        path = find_cache_miss_csv(arch)
        if path is None:
            print(f"[WARN] {arch}: summary.csv not found")
            continue
        print(f"[INFO] {arch}: {path}")
        raw  = parse_summary(path)
        agg, master_qps = aggregate(raw)
        datasets[arch] = {"rows": agg, "master_qps": master_qps}
    return datasets


def spinonly(rows):
    """master を除いた N>=0 の行のみ返す"""
    return [r for r in rows if r["n"] >= 0]


# -------------------------------------------------------------------
# Plot helpers
# -------------------------------------------------------------------

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
# Plot 1: QPS vs N
# -------------------------------------------------------------------

def plot_qps(datasets):
    fig, ax = setup_fig()

    for arch, info in ARCH_INFO.items():
        if arch not in datasets:
            continue
        rows = spinonly(datasets[arch]["rows"])
        ns   = [r["n"]        for r in rows]
        qs   = [r["qps_mean"] / 1e3 for r in rows]
        errs = [r["qps_std"]  / 1e3 for r in rows]
        ax.errorbar(ns, qs, yerr=errs, label=info["label"], color=info["color"],
                    marker="o", markersize=3, linewidth=1.2, capsize=2)

        master_qps = datasets[arch]["master_qps"]
        if master_qps is not None:
            ax.axhline(master_qps / 1e3, color=info["color"], linestyle="--",
                       linewidth=0.8, alpha=0.6)

    ax.set_xlabel("pause_per_round (N)")
    ax.set_ylabel("QPS (K req/s)")
    ax.set_title("Throughput vs PAUSE count")
    ax.legend(fontsize=9)
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    fig.tight_layout()
    save(fig, "cache_miss_qps.pdf")


# -------------------------------------------------------------------
# Plot 2: demand_rfo / req vs N
# -------------------------------------------------------------------

def plot_demand_rfo(datasets):
    fig, ax = setup_fig()

    for arch, info in ARCH_INFO.items():
        if arch not in datasets:
            continue
        rows = spinonly(datasets[arch]["rows"])
        ns   = [r["n"]               for r in rows]
        rfo  = [r["rfo_per_req"]     for r in rows]
        errs = [r["rfo_per_req_std"] for r in rows]
        ax.errorbar(ns, rfo, yerr=errs, label=info["label"], color=info["color"],
                    marker="o", markersize=3, linewidth=1.2, capsize=2)

    ax.set_xlabel("pause_per_round (N)")
    ax.set_ylabel("demand_rfo / request")
    ax.set_title("Bus contention (offcore RFO) vs PAUSE count")
    ax.legend(fontsize=9)
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    fig.tight_layout()
    save(fig, "cache_miss_demand_rfo.pdf")


# -------------------------------------------------------------------
# Plot 3: QPS + demand_rfo/req 二軸（per-arch, 2 subplots）
# -------------------------------------------------------------------

def plot_qps_rfo_overlay(datasets):
    archs = [a for a in ARCH_INFO if a in datasets]
    if not archs:
        return

    fig, axes = plt.subplots(1, len(archs), figsize=(6 * len(archs), 4.5))
    if len(archs) == 1:
        axes = [axes]

    for ax, arch in zip(axes, archs):
        info = ARCH_INFO[arch]
        rows = spinonly(datasets[arch]["rows"])
        ns   = [r["n"]            for r in rows]
        qs   = [r["qps_mean"]/1e3 for r in rows]
        rfo  = [r["rfo_per_req"]  for r in rows]

        color_qps = info["color"]
        color_rfo = "tab:orange"

        ax.set_xlabel("pause_per_round (N)")
        ax.spines["top"].set_visible(False)

        l1, = ax.plot(ns, qs, color=color_qps, marker="o", markersize=3,
                      linewidth=1.4, label="QPS (K req/s)")
        ax.set_ylabel("QPS (K req/s)", color=color_qps)
        ax.tick_params(axis="y", labelcolor=color_qps)

        ax2 = ax.twinx()
        l2, = ax2.plot(ns, rfo, color=color_rfo, marker="s", markersize=3,
                       linewidth=1.4, linestyle="--", label="demand_rfo/req")
        ax2.set_ylabel("demand_rfo / request", color=color_rfo)
        ax2.tick_params(axis="y", labelcolor=color_rfo)
        ax2.spines["top"].set_visible(False)

        # master 基準線
        master_qps = datasets[arch]["master_qps"]
        if master_qps is not None:
            ax.axhline(master_qps / 1e3, color=color_qps, linestyle=":",
                       linewidth=0.8, alpha=0.5, label="master QPS")

        ax.set_title(info["label"], fontsize=9)
        ax.grid(axis="x", linestyle=":", alpha=0.3)

        lines = [l1, l2]
        labels = [l.get_label() for l in lines]
        ax.legend(lines, labels, fontsize=8, loc="lower right")

    fig.suptitle("QPS and Bus Contention vs PAUSE count", fontsize=11, y=1.01)
    fig.tight_layout()
    save(fig, "cache_miss_qps_rfo_overlay.pdf")


# -------------------------------------------------------------------
# Plot 4: p999 latency vs N
# -------------------------------------------------------------------

def plot_p999(datasets):
    fig, ax = setup_fig()

    for arch, info in ARCH_INFO.items():
        if arch not in datasets:
            continue
        rows = spinonly(datasets[arch]["rows"])
        ns   = [r["n"]          for r in rows]
        p999 = [r["p999_mean"]  for r in rows]
        errs = [r["p999_std"]   for r in rows]
        ax.errorbar(ns, p999, yerr=errs, label=info["label"], color=info["color"],
                    marker="o", markersize=3, linewidth=1.2, capsize=2)

    ax.set_xlabel("pause_per_round (N)")
    ax.set_ylabel("p999 latency (μs)")
    ax.set_title("Tail latency (p999) vs PAUSE count")
    ax.legend(fontsize=9)
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    fig.tight_layout()
    save(fig, "cache_miss_p999.pdf")


# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------

if __name__ == "__main__":
    datasets = load_all()
    if not datasets:
        print("[ERROR] No data found. Run cache miss sweep first.")
        raise SystemExit(1)

    plot_qps(datasets)
    plot_demand_rfo(datasets)
    plot_qps_rfo_overlay(datasets)
    plot_p999(datasets)

    print(f"\nDone. PDFs saved to: {OUTPUT_DIR}")
