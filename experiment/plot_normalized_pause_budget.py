#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_normalized_pause_budget.py
#
# Description:
#   横軸を N ではなく N × PAUSE_CYC（スピン1ラウンドあたりの総PAUSEサイクル数）に正規化し、
#   複数アーキテクチャのQPS曲線を重ねてプロットする。
#
#   曲線が一致 → PAUSEサイクル数だけで性能差が説明できる
#   曲線がずれる → L3キャッシュサイズ・トポロジー等の他要因が効いている
#
# Parameters (env vars):
#   OUTPUT_DIR - 出力先 (default: experiment/results/plots/v2)
#
# Output:
#   $OUTPUT_DIR/qps_normalized_pause_budget.pdf
#   $OUTPUT_DIR/qps_normalized_pause_budget_relative.pdf  (master比正規化)
#
# Prerequisites:
#   pip install matplotlib numpy scipy

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

# PAUSEサイクル数（実測値 -O2コンパイル）
PAUSE_CYC = {
    "broadwell":     10,
    "icelake":       39,
    "skylake_ann":   124,
    "emeraldrapids": 37,  # 未測定(-O2)、旧来の推定値
}

ARCH_INFO = {
    "broadwell":     {"label": "Broadwell   E5-2640v4  PAUSE~10cy  L3=25MB/socket", "color": "tab:blue"},
    "icelake":       {"label": "Sunny Cove  Silver4314 PAUSE~39cy  L3=24MB/socket", "color": "tab:orange"},
    "skylake_ann":   {"label": "Skylake     Silver4110 PAUSE~124cy L3=11MB",        "color": "tab:green"},
    "emeraldrapids": {"label": "Emrld.Rapids Gold6554S PAUSE~37cy  L3=?MB",         "color": "tab:red"},
}

RAW_CSV = {
    "broadwell":   "experiment/results/broadwell/utdelay_p999_20260707_022638/raw.csv",
    "icelake":     "experiment/results/icelake/utdelay_p999_20260707_090726/raw.csv",
    "skylake_ann": "experiment/results/utdelay_p999_20260708_233528/raw.csv",
}


def load_qps(path):
    """raw.csv → {n: [qps, ...], "master": [qps, ...]}"""
    data = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            key = row["label"]
            if key == "master":
                data.setdefault("master", []).append(float(row["QPS"]))
            else:
                m = re.match(r"N(\d+)$", key)
                if m:
                    n = int(m.group(1))
                    data.setdefault(n, []).append(float(row["QPS"]))
    return data


def median(vals):
    s = sorted(vals)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n//2 - 1] + s[n//2]) / 2


def save(fig, name):
    path = os.path.join(OUTPUT_DIR, name)
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved: {path}")


# -------------------------------------------------------------------
# Plot 1: QPS vs N × PAUSE_CYC（絶対値）
# -------------------------------------------------------------------
def plot_abs(datasets):
    fig, ax = plt.subplots(figsize=(10, 5.5))
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    for arch, data in datasets.items():
        info  = ARCH_INFO[arch]
        pcyc  = PAUSE_CYC[arch]
        ns    = sorted(n for n in data if n != "master")
        budgets = np.array([n * pcyc for n in ns], dtype=float)
        qps     = np.array([median(data[n]) for n in ns], dtype=float)

        xs = np.linspace(budgets[0], budgets[-1], 500)
        ax.plot(xs, PchipInterpolator(budgets, qps)(xs) / 1e3,
                color=info["color"], linewidth=1.8, label=info["label"])
        ax.scatter(budgets, qps / 1e3, color=info["color"], s=18, zorder=5)

        # masterベースライン
        base = median(data["master"]) / 1e3
        ax.axhline(base, color=info["color"], linestyle="--",
                   linewidth=1.2, alpha=0.6)

    ax.set_xlabel("N × PAUSEサイクル数（スピン1ラウンドの総サイクル）", fontsize=13)
    ax.set_ylabel("スループット [Kqps]", fontsize=13)
    ax.set_title("QPS vs スピンコスト正規化（N × PAUSE_CYC）", fontsize=14)
    ax.legend(fontsize=11, loc="lower left")
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    fig.tight_layout()
    save(fig, "qps_normalized_pause_budget.pdf")


# -------------------------------------------------------------------
# Plot 2: master比正規化QPS vs N × PAUSE_CYC
# -------------------------------------------------------------------
def plot_relative(datasets):
    fig, ax = plt.subplots(figsize=(10, 5.5))
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.axhline(1.0, color="grey", linestyle="--", linewidth=1.0,
               alpha=0.6, label="master baseline (=1.0)")

    for arch, data in datasets.items():
        info  = ARCH_INFO[arch]
        pcyc  = PAUSE_CYC[arch]
        base  = median(data["master"])
        ns    = sorted(n for n in data if n != "master")
        budgets = np.array([n * pcyc for n in ns], dtype=float)
        rel     = np.array([median(data[n]) / base for n in ns], dtype=float)

        xs = np.linspace(budgets[0], budgets[-1], 500)
        ax.plot(xs, PchipInterpolator(budgets, rel)(xs),
                color=info["color"], linewidth=1.8, label=info["label"])
        ax.scatter(budgets, rel, color=info["color"], s=18, zorder=5)

    ax.set_xlabel("N × PAUSEサイクル数（スピン1ラウンドの総サイクル）", fontsize=13)
    ax.set_ylabel("正規化 QPS（masterを1.0）", fontsize=13)
    ax.set_title("正規化QPS vs スピンコスト（PAUSEサイクル数で正規化）", fontsize=14)
    ax.legend(fontsize=11, loc="lower left")
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    fig.tight_layout()
    save(fig, "qps_normalized_pause_budget_relative.pdf")


# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
if __name__ == "__main__":
    datasets = {}
    for arch, path in RAW_CSV.items():
        if not os.path.exists(path):
            print(f"[WARN] {arch}: {path} not found, skipping")
            continue
        print(f"[INFO] {arch}: {path}")
        datasets[arch] = load_qps(path)

    if not datasets:
        print("[ERROR] No data found.")
        raise SystemExit(1)

    plot_abs(datasets)
    plot_relative(datasets)
    print(f"\nDone. PDFs saved to: {OUTPUT_DIR}")
