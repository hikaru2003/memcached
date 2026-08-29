#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_approach_a.py
#   OUTPUT_DIR=experiment/results/plots/approach_a python3 experiment/plot_approach_a.py
#
# Description:
#   Approach A（MC_THREADS=2/4/8, 固定N）の結果を可視化する。
#   「スレッド増加 → RFO増加 → handoff latency増加」の因果を確認する。
#
#   生成グラフ:
#   1. approach_a_handoff_vs_threads.pdf — handoff p99/p999 vs MC_THREADS (N別, アーキ比較)
#   2. approach_a_rfo_vs_threads.pdf     — demand_rfo/req vs MC_THREADS (N別, アーキ比較)
#   3. approach_a_rfo_vs_handoff.pdf     — demand_rfo/req vs handoff p99 散布図（因果確認）
#   4. approach_a_qps_vs_threads.pdf     — QPS vs MC_THREADS (N別, アーキ比較)
#
# Parameters (env vars):
#   RESULTS_BASE - 結果ディレクトリ (default: experiment/results)
#   OUTPUT_DIR   - 出力先 (default: experiment/results/plots/approach_a)
#
# Output:
#   $OUTPUT_DIR/approach_a_handoff_vs_threads.pdf
#   $OUTPUT_DIR/approach_a_rfo_vs_threads.pdf
#   $OUTPUT_DIR/approach_a_rfo_vs_handoff.pdf
#   $OUTPUT_DIR/approach_a_qps_vs_threads.pdf
#
# Prerequisites:
#   pip install matplotlib numpy
#   experiment/results/{arch}/handoff_*/handoff_summary.csv
#   experiment/results/{arch}/cache_miss_*/summary.csv

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

RESULTS_BASE = os.environ.get("RESULTS_BASE", "experiment/results")
OUTPUT_DIR   = os.environ.get("OUTPUT_DIR",
               os.path.join(RESULTS_BASE, "plots", "approach_a"))
os.makedirs(OUTPUT_DIR, exist_ok=True)

ARCH_INFO = {
    "broadwell":     {"label": "Broadwell (PAUSE~10cy)",      "color": "tab:blue",   "marker": "o"},
    "icelake":       {"label": "Sunny Cove (PAUSE~39cy)",     "color": "tab:orange", "marker": "s"},
    "emeraldrapids": {"label": "Emerald Rapids (PAUSE~22cy)", "color": "tab:red",    "marker": "^"},
}

THREAD_COUNTS = [2, 4, 8]
N_HIGHLIGHT   = [0, 25, 50, 100, 200]  # グラフに描画するN値


# -----------------------------------------------------------------------
# データ収集
# -----------------------------------------------------------------------

def get_mc_threads(run_info_path):
    """run_info.md から mc_threads を取得する"""
    with open(run_info_path) as f:
        for line in f:
            m = re.match(r"- mc_threads:\s*(\d+)", line)
            if m:
                return int(m.group(1))
    return None


def find_handoff_dirs(arch):
    """arch の handoff_* ディレクトリを {mc_threads: path} にまとめる（最新を使用）"""
    result = {}
    dirs = sorted(glob.glob(os.path.join(RESULTS_BASE, arch, "handoff_*")))
    for d in dirs:
        run_info = os.path.join(d, "run_info.md")
        summary  = os.path.join(d, "handoff_summary.csv")
        if not (os.path.exists(run_info) and os.path.exists(summary)):
            continue
        t = get_mc_threads(run_info)
        if t is not None:
            result[t] = d  # 後から来るものが新しい（sorted で昇順）
    return result


def find_cache_miss_dirs(arch):
    """arch の cache_miss_* ディレクトリを {mc_threads: path} にまとめる（最新を使用）"""
    result = {}
    dirs = sorted(glob.glob(os.path.join(RESULTS_BASE, arch, "cache_miss_*")))
    for d in dirs:
        run_info = os.path.join(d, "run_info.md")
        summary  = os.path.join(d, "summary.csv")
        if not (os.path.exists(run_info) and os.path.exists(summary)):
            continue
        t = get_mc_threads(run_info)
        if t is not None:
            result[t] = d
    return result


def load_handoff(path):
    """handoff_summary.csv → {N: {p50, p99, p999}} (µs)"""
    data = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            m = re.match(r"N(\d+)$", row["condition"])
            if not m:
                continue
            n = int(m.group(1))
            data[n] = {
                "p50":  float(row["p50_us"]),
                "p99":  float(row["p99_us"]),
                "p999": float(row["p999_us"]),
            }
    return data


def load_cache_miss(path):
    """summary.csv → {N: {qps_mean, rfo_per_req_mean}}"""
    raw = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            m = re.match(r"N(\d+)$", row["label"])
            if not m:
                continue
            n   = int(m.group(1))
            qps = float(row["QPS"])
            rfo = float(row["demand_rfo"]) if row["demand_rfo"] not in ("", "N/A") else None
            raw.setdefault(n, {"qps": [], "rfo": []})
            raw[n]["qps"].append(qps)
            if rfo is not None:
                raw[n]["rfo"].append(rfo)

    data = {}
    for n, vals in raw.items():
        if not vals["qps"]:
            continue
        qps_mean = np.mean(vals["qps"])
        # demand_rfo/req = demand_rfo / (QPS × 60s)
        if vals["rfo"]:
            rfo_per_req = np.mean(vals["rfo"]) / (qps_mean * 60)
        else:
            rfo_per_req = None
        data[n] = {"qps": qps_mean, "rfo_per_req": rfo_per_req}
    return data


def load_all():
    """全アーキ × 全スレッド数のデータを収集"""
    datasets = {}
    for arch in ARCH_INFO:
        h_dirs = find_handoff_dirs(arch)
        c_dirs = find_cache_miss_dirs(arch)
        if not h_dirs and not c_dirs:
            print(f"[WARN] {arch}: no approach_a data found, skipping")
            continue
        print(f"[INFO] {arch}: handoff T={sorted(h_dirs)}, cache_miss T={sorted(c_dirs)}")
        datasets[arch] = {}
        for t in THREAD_COUNTS:
            entry = {"t": t}
            if t in h_dirs:
                entry["handoff"] = load_handoff(
                    os.path.join(h_dirs[t], "handoff_summary.csv"))
            if t in c_dirs:
                entry["cache_miss"] = load_cache_miss(
                    os.path.join(c_dirs[t], "summary.csv"))
            if len(entry) > 1:
                datasets[arch][t] = entry
    return datasets


# -----------------------------------------------------------------------
# Plot 1: handoff p99/p999 vs MC_THREADS
# -----------------------------------------------------------------------

def plot_handoff_vs_threads(datasets):
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    ax_p99, ax_p999 = axes
    for ax in axes:
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)

    for arch, info in ARCH_INFO.items():
        if arch not in datasets:
            continue
        d = datasets[arch]

        for n_val in N_HIGHLIGHT:
            ts  = sorted(t for t in d if "handoff" in d[t] and n_val in d[t]["handoff"])
            if not ts:
                continue
            p99s  = [d[t]["handoff"][n_val]["p99"]  for t in ts]
            p999s = [d[t]["handoff"][n_val]["p999"] for t in ts]
            alpha = 1.0 if n_val == 0 else 0.55
            lw    = 2.0 if n_val == 0 else 1.2
            ls    = "-"  if n_val == 0 else "--"
            lbl   = f"{info['label']}  N={n_val}" if n_val == 0 else f"N={n_val}"
            c     = info["color"]

            ax_p99.plot(ts, p99s,   color=c, lw=lw, ls=ls, alpha=alpha,
                        marker=info["marker"], ms=6,
                        label=lbl if n_val == 0 else f"{arch} N={n_val}")
            ax_p999.plot(ts, p999s, color=c, lw=lw, ls=ls, alpha=alpha,
                         marker=info["marker"], ms=6,
                         label=lbl if n_val == 0 else f"{arch} N={n_val}")

    for ax, title, ylabel in [
        (ax_p99,  "handoff p99 vs MC_THREADS",   "handoff p99 [µs]"),
        (ax_p999, "handoff p999 vs MC_THREADS",  "handoff p999 [µs]"),
    ]:
        ax.set_xlabel("MC_THREADS", fontsize=12)
        ax.set_ylabel(ylabel, fontsize=12)
        ax.set_title(title, fontsize=13)
        ax.set_xticks(THREAD_COUNTS)
        ax.legend(fontsize=9, loc="upper left")
        ax.grid(axis="y", linestyle=":", alpha=0.4)

    fig.suptitle("Approach A: handoff latency vs スレッド数（固定N）", fontsize=14)
    fig.tight_layout()
    path = os.path.join(OUTPUT_DIR, "approach_a_handoff_vs_threads.pdf")
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved: {path}")


# -----------------------------------------------------------------------
# Plot 2: demand_rfo/req vs MC_THREADS
# -----------------------------------------------------------------------

def plot_rfo_vs_threads(datasets):
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    for arch, info in ARCH_INFO.items():
        if arch not in datasets:
            continue
        d = datasets[arch]

        for n_val in N_HIGHLIGHT:
            ts   = sorted(t for t in d if "cache_miss" in d[t]
                          and n_val in d[t]["cache_miss"]
                          and d[t]["cache_miss"][n_val]["rfo_per_req"] is not None)
            if not ts:
                continue
            rfos = [d[t]["cache_miss"][n_val]["rfo_per_req"] for t in ts]
            alpha = 1.0 if n_val == 0 else 0.55
            lw    = 2.0 if n_val == 0 else 1.2
            ls    = "-"  if n_val == 0 else "--"

            ax.plot(ts, rfos, color=info["color"], lw=lw, ls=ls, alpha=alpha,
                    marker=info["marker"], ms=6,
                    label=f"{info['label']} N={n_val}")

    ax.set_xlabel("MC_THREADS", fontsize=12)
    ax.set_ylabel("demand_rfo / req", fontsize=12)
    ax.set_title("Approach A: demand_rfo/req vs スレッド数（固定N）", fontsize=13)
    ax.set_xticks(THREAD_COUNTS)
    ax.legend(fontsize=9, loc="upper left")
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    fig.tight_layout()
    path = os.path.join(OUTPUT_DIR, "approach_a_rfo_vs_threads.pdf")
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved: {path}")


# -----------------------------------------------------------------------
# Plot 3: demand_rfo/req vs handoff p99 散布図（因果確認）
# -----------------------------------------------------------------------

def plot_rfo_vs_handoff(datasets):
    fig, ax = plt.subplots(figsize=(8, 6))
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    for arch, info in ARCH_INFO.items():
        if arch not in datasets:
            continue
        d = datasets[arch]
        xs, ys, labels = [], [], []

        for t in THREAD_COUNTS:
            if t not in d:
                continue
            entry = d[t]
            for n_val in N_HIGHLIGHT:
                h = entry.get("handoff", {}).get(n_val)
                c = entry.get("cache_miss", {}).get(n_val)
                if h is None or c is None or c["rfo_per_req"] is None:
                    continue
                xs.append(c["rfo_per_req"])
                ys.append(h["p99"])
                labels.append(f"T={t} N={n_val}")

        if xs:
            sc = ax.scatter(xs, ys, color=info["color"], marker=info["marker"],
                            s=60, zorder=5, label=info["label"])
            for x, y, lbl in zip(xs, ys, labels):
                ax.annotate(lbl, (x, y), fontsize=7, alpha=0.7,
                            xytext=(4, 2), textcoords="offset points")

    ax.set_xlabel("demand_rfo / req", fontsize=12)
    ax.set_ylabel("handoff p99 [µs]", fontsize=12)
    ax.set_title("demand_rfo/req vs handoff p99（因果確認）", fontsize=13)
    ax.legend(fontsize=10)
    ax.grid(linestyle=":", alpha=0.4)
    fig.tight_layout()
    path = os.path.join(OUTPUT_DIR, "approach_a_rfo_vs_handoff.pdf")
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved: {path}")


# -----------------------------------------------------------------------
# Plot 4: QPS vs MC_THREADS
# -----------------------------------------------------------------------

def plot_qps_vs_threads(datasets):
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    for arch, info in ARCH_INFO.items():
        if arch not in datasets:
            continue
        d = datasets[arch]

        for n_val in N_HIGHLIGHT:
            ts   = sorted(t for t in d if "cache_miss" in d[t]
                          and n_val in d[t]["cache_miss"])
            if not ts:
                continue
            qpss = [d[t]["cache_miss"][n_val]["qps"] / 1e3 for t in ts]
            alpha = 1.0 if n_val == 0 else 0.55
            lw    = 2.0 if n_val == 0 else 1.2
            ls    = "-"  if n_val == 0 else "--"

            ax.plot(ts, qpss, color=info["color"], lw=lw, ls=ls, alpha=alpha,
                    marker=info["marker"], ms=6,
                    label=f"{info['label']} N={n_val}")

    ax.set_xlabel("MC_THREADS", fontsize=12)
    ax.set_ylabel("QPS [Kqps]", fontsize=12)
    ax.set_title("Approach A: QPS vs スレッド数（固定N）", fontsize=13)
    ax.set_xticks(THREAD_COUNTS)
    ax.legend(fontsize=9, loc="upper left")
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    fig.tight_layout()
    path = os.path.join(OUTPUT_DIR, "approach_a_qps_vs_threads.pdf")
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved: {path}")


# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------

if __name__ == "__main__":
    datasets = load_all()
    if not datasets:
        print("[ERROR] No approach_a data found.")
        raise SystemExit(1)

    plot_handoff_vs_threads(datasets)
    plot_rfo_vs_threads(datasets)
    plot_rfo_vs_handoff(datasets)
    plot_qps_vs_threads(datasets)

    print(f"\nDone. PDFs saved to: {OUTPUT_DIR}")
