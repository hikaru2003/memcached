#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_futex_comparison.py
#   OUTPUT_DIR=experiment/results/plots/v3 python3 experiment/plot_futex_comparison.py
#
# Description:
#   Broadwell / Ice Lake / Skylake ann の futex sweep 実験結果を可視化する。
#   「PAUSEがfutex呼び出しを削減 → ロック競合改善」を示す4種のグラフを生成する。
#   1. QPS vs N                        — 3アーキ比較, エラーバー=±1σ
#   2. futex_count / req vs N          — futex削減効果, 3アーキ比較
#   3. QPS + futex/req 二軸グラフ      — per-arch 3 subplots
#   4. p999 latency vs N               — 3アーキ比較
#
# Parameters (env vars):
#   OUTPUT_DIR - 出力先ディレクトリ (default: experiment/results/plots/v2)
#
# Output:
#   $OUTPUT_DIR/futex_qps.pdf
#   $OUTPUT_DIR/futex_per_req.pdf
#   $OUTPUT_DIR/futex_qps_overlay.pdf
#   $OUTPUT_DIR/futex_p999.pdf
#
# Prerequisites:
#   pip install matplotlib numpy
#   experiment/results/broadwell/futex_*/summary.csv    (Broadwell)
#   experiment/results/icelake/futex_*/summary.csv      (Ice Lake)
#   experiment/results/skylake_ann/futex_*/summary.csv  (Skylake ann)

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

DURATION_SEC = 60

ARCH_INFO = {
    "broadwell":   {"label": "Broadwell   E5-2640v4  PAUSE~10cy  L3=25MB/socket", "color": "tab:blue"},
    "icelake":     {"label": "Sunny Cove  Silver4314 PAUSE~39cy  L3=24MB/socket", "color": "tab:orange"},
    "skylake_ann": {"label": "Skylake     Silver4110 PAUSE~124cy L3=11MB",        "color": "tab:green"},
}


def find_futex_csv(arch):
    cands = sorted(glob.glob(os.path.join(RESULTS_BASE, arch, "futex_*", "summary.csv")))
    return cands[-1] if cands else None


def parse_summary(path):
    data = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            label = row["label"]
            if label not in data:
                data[label] = {"qps": [], "p99": [], "p999": [], "futex_per_req": []}
            try:
                data[label]["qps"].append(float(row["QPS"]))
                data[label]["p99"].append(float(row["r_p99_us"]))
                data[label]["p999"].append(float(row["r_p999_us"]))
                data[label]["futex_per_req"].append(float(row["futex_per_req"]))
            except (ValueError, KeyError):
                pass
    return data


def aggregate(data):
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
        qps_std   = np.std(vals["qps"],  ddof=1) if len(vals["qps"]) > 1 else 0.0
        p99_mean  = np.mean(vals["p99"])
        p99_std   = np.std(vals["p99"],  ddof=1) if len(vals["p99"]) > 1 else 0.0
        p999_mean = np.mean(vals["p999"])
        p999_std  = np.std(vals["p999"], ddof=1) if len(vals["p999"]) > 1 else 0.0
        fpr_mean  = np.mean(vals["futex_per_req"])
        fpr_std   = np.std(vals["futex_per_req"], ddof=1) if len(vals["futex_per_req"]) > 1 else 0.0

        if label == "master":
            master_qps = qps_mean

        rows.append({
            "label": label, "n": n,
            "qps_mean": qps_mean, "qps_std": qps_std,
            "p99_mean": p99_mean, "p99_std": p99_std,
            "p999_mean": p999_mean, "p999_std": p999_std,
            "fpr_mean": fpr_mean, "fpr_std": fpr_std,
        })

    rows.sort(key=lambda r: r["n"])
    return rows, master_qps


def load_all():
    datasets = {}
    for arch in ARCH_INFO:
        path = find_futex_csv(arch)
        if path is None:
            print(f"[WARN] {arch}: summary.csv not found")
            continue
        print(f"[INFO] {arch}: {path}")
        raw = parse_summary(path)
        agg, master_qps = aggregate(raw)
        datasets[arch] = {"rows": agg, "master_qps": master_qps}
    return datasets


def spinonly(rows):
    return [r for r in rows if r["n"] >= 0]


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
    save(fig, "futex_qps.pdf")


# -------------------------------------------------------------------
# Plot 2: futex / req vs N
# -------------------------------------------------------------------

def plot_futex_per_req(datasets):
    fig, ax = setup_fig()
    for arch, info in ARCH_INFO.items():
        if arch not in datasets:
            continue
        rows = spinonly(datasets[arch]["rows"])
        ns   = [r["n"]        for r in rows]
        fpr  = [r["fpr_mean"] for r in rows]
        errs = [r["fpr_std"]  for r in rows]
        ax.errorbar(ns, fpr, yerr=errs, label=info["label"], color=info["color"],
                    marker="o", markersize=3, linewidth=1.2, capsize=2)
    ax.set_xlabel("pause_per_round (N)")
    ax.set_ylabel("futex calls / request")
    ax.set_title("Futex syscall rate vs PAUSE count")
    ax.legend(fontsize=9)
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    fig.tight_layout()
    save(fig, "futex_per_req.pdf")


# -------------------------------------------------------------------
# Plot 3: QPS + futex/req 二軸（per-arch, 2 subplots）
# -------------------------------------------------------------------

def plot_qps_futex_overlay(datasets):
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
        fpr  = [r["fpr_mean"]     for r in rows]

        color_qps = info["color"]
        color_fpr = "tab:orange"

        ax.set_xlabel("pause_per_round (N)")
        ax.spines["top"].set_visible(False)

        l1, = ax.plot(ns, qs, color=color_qps, marker="o", markersize=3,
                      linewidth=1.4, label="QPS (K req/s)")
        ax.set_ylabel("QPS (K req/s)", color=color_qps)
        ax.tick_params(axis="y", labelcolor=color_qps)

        ax2 = ax.twinx()
        l2, = ax2.plot(ns, fpr, color=color_fpr, marker="s", markersize=3,
                       linewidth=1.4, linestyle="--", label="futex/req")
        ax2.set_ylabel("futex calls / request", color=color_fpr)
        ax2.tick_params(axis="y", labelcolor=color_fpr)
        ax2.spines["top"].set_visible(False)

        master_qps = datasets[arch]["master_qps"]
        if master_qps is not None:
            ax.axhline(master_qps / 1e3, color=color_qps, linestyle=":",
                       linewidth=0.8, alpha=0.5, label="master QPS")

        ax.set_title(info["label"], fontsize=9)
        ax.grid(axis="x", linestyle=":", alpha=0.3)

        lines = [l1, l2]
        labels = [l.get_label() for l in lines]
        ax.legend(lines, labels, fontsize=8, loc="upper right")

    fig.suptitle("QPS and Futex Syscall Rate vs PAUSE count", fontsize=11, y=1.01)
    fig.tight_layout()
    save(fig, "futex_qps_overlay.pdf")


# -------------------------------------------------------------------
# Plot 4: p999 latency vs N
# -------------------------------------------------------------------

def plot_p999(datasets):
    fig, ax = setup_fig()
    for arch, info in ARCH_INFO.items():
        if arch not in datasets:
            continue
        rows = spinonly(datasets[arch]["rows"])
        ns   = [r["n"]         for r in rows]
        p999 = [r["p999_mean"] for r in rows]
        errs = [r["p999_std"]  for r in rows]
        ax.errorbar(ns, p999, yerr=errs, label=info["label"], color=info["color"],
                    marker="o", markersize=3, linewidth=1.2, capsize=2)
    ax.set_xlabel("pause_per_round (N)")
    ax.set_ylabel("p999 latency (μs)")
    ax.set_title("Tail latency (p999) vs PAUSE count")
    ax.legend(fontsize=9)
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    fig.tight_layout()
    save(fig, "futex_p999.pdf")


# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------

if __name__ == "__main__":
    datasets = load_all()
    if not datasets:
        print("[ERROR] No data found. Run futex sweep first.")
        raise SystemExit(1)

    plot_qps(datasets)
    plot_futex_per_req(datasets)
    plot_qps_futex_overlay(datasets)
    plot_p999(datasets)

    print(f"\nDone. PDFs saved to: {OUTPUT_DIR}")
