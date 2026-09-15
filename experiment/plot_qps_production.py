#!/usr/bin/env python3
"""
Usage:
    python3 experiment/plot_qps_production.py

Description:
    2026-09-13/14 の本番 utdelay_sweep_p999 実験の QPS を 3 アーキで比較する。
    本番の特徴 (smoke test と区別する目的):
      - 環境設定: SMT off / governor performance / turbo off / freq pinned to base clock
      - 統計精度: warmup 120s + duration 60s × 30 runs per N
      - N grid: 40 点 (低 N を密に、peak 周辺 N=5-30 を細かく)

    生成グラフ:
      1. qps_comparison_production_n30.pdf   - 生 QPS ± 1σ (絶対値)
      2. qps_normalized_production_n30.pdf   - master 比正規化 QPS
      3. qps_pause_budget_production_n30.pdf - x軸を PAUSE budget (N × PAUSE cy) に変換

Parameters:
    ハードコード (raw.csv パス):
      broadwell:     experiment/results/broadwell/utdelay_p999_20260912_073656/raw.csv
      icelake:       experiment/results/icelake/utdelay_p999_20260912_133715/raw.csv
      emeraldrapids: experiment/results/emeraldrapids/utdelay_p999_20260912_133716/raw.csv

Output:
    experiment/results/plots/v4/qps_comparison_production_n30.pdf
    experiment/results/plots/v4/qps_normalized_production_n30.pdf
    experiment/results/plots/v4/qps_pause_budget_production_n30.pdf

Prerequisites:
    pip install matplotlib numpy
    上記 3 raw.csv が存在すること (git archive myfork/experiment/results/<arch>-utdelay-YYYYMMDD -- ...)
"""
import csv
import math
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import numpy as np
from scipy.interpolate import PchipInterpolator
from scipy.ndimage import gaussian_filter1d


# ---------------------------------------------------------------------------
# データ設定
# ---------------------------------------------------------------------------

DATA = {
    "broadwell": {
        "csv":       "experiment/results/broadwell/utdelay_p999_20260912_073656/raw.csv",
        "label":     "Broadwell (xl170, PAUSE~10cy)",
        "color":     "tab:blue",
        "pause_cy":  10.0,
    },
    "icelake": {
        "csv":       "experiment/results/icelake/utdelay_p999_20260912_133715/raw.csv",
        "label":     "Sunny Cove (sm110p, PAUSE~39cy)",
        "color":     "tab:orange",
        "pause_cy":  39.0,
    },
    "emeraldrapids": {
        "csv":       "experiment/results/emeraldrapids/utdelay_p999_20260912_133716/raw.csv",
        "label":     "Emerald Rapids (c6620, PAUSE~37cy)",
        "color":     "tab:red",
        "pause_cy":  37.0,
    },
    "skylake": {
        "csv":       "experiment/results/skylake/utdelay_p999_20260913_203737/raw.csv",
        "label":     "Skylake (c220g5, PAUSE~142cy)",
        "color":     "tab:green",
        "pause_cy":  142.0,
    },
}

OUTDIR = "experiment/results/plots/v4"

FIG_META = ("Production run (env pinned, warmup 120s + 60s × 30 runs/N, 40 N grid)\n"
            "commit 87cd2ba9 / dates 2026-09-13 (Broadwell/Skylake) & 2026-09-14 (Sunny Cove/Emerald)")


# ---------------------------------------------------------------------------
# CSV パース
# ---------------------------------------------------------------------------

def stddev(vals):
    if len(vals) < 2:
        return 0.0
    m = sum(vals) / len(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / (len(vals) - 1))


def parse_raw_csv(path):
    """raw.csv を label -> [qps, ...] にする。master は N=None として保持。"""
    per_label = {}
    with open(path) as f:
        r = csv.DictReader(f)
        for row in r:
            lab = row["label"]
            try:
                per_label.setdefault(lab, []).append(float(row["QPS"]))
            except (KeyError, ValueError):
                continue
    return per_label


def aggregate(per_label):
    """label -> (N or None, mean, sd) にまとめる。N ソート済みリストで返す。master は分離。"""
    master = None
    entries = []
    for lab, vals in per_label.items():
        if not vals:
            continue
        mean = sum(vals) / len(vals)
        sd = stddev(vals)
        if lab == "master":
            master = (mean, sd)
        else:
            # "N0" -> 0, "N125" -> 125
            try:
                n = int(lab.lstrip("N"))
                entries.append((n, mean, sd))
            except ValueError:
                pass
    entries.sort(key=lambda t: t[0])
    return master, entries


# ---------------------------------------------------------------------------
# プロット関数
# ---------------------------------------------------------------------------

def _load_all():
    result = {}
    for arch, cfg in DATA.items():
        if not os.path.exists(cfg["csv"]):
            print(f"[WARN] missing: {cfg['csv']}")
            continue
        per_label = parse_raw_csv(cfg["csv"])
        master, entries = aggregate(per_label)
        result[arch] = {
            "cfg":     cfg,
            "master":  master,
            "entries": entries,
        }
        peak_n, peak_qps, _ = max(entries, key=lambda t: t[1])
        print(f"[INFO] {arch}: master={master[0]/1e3:.0f}k  peak N={peak_n} ({peak_qps/1e3:.0f}k)")
    return result


def _smooth_curve(xs_data, ys_data, n_samples=500, sigma_frac=0.02):
    """PCHIP で密な補間を作った後、Gaussian で平滑化して論文向けの滑らかな曲線を返す。

    - PCHIP: piecewise cubic Hermite (monotonic-preserving)、peak を overshoot しない
    - Gaussian: N=[0..200] の 500 点の内 sigma=n_samples*sigma_frac (default 10 点) で平滑化

    sigma_frac を大きくすると更に滑らか、小さくすると原データに忠実。
    """
    xs = np.linspace(min(xs_data), max(xs_data), n_samples)
    ys = PchipInterpolator(xs_data, ys_data)(xs)
    ys = gaussian_filter1d(ys, sigma=n_samples * sigma_frac)
    return xs, ys


def plot_qps_abs(data, outpath):
    fig, ax = plt.subplots(figsize=(9.5, 5.5))
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    for arch, d in data.items():
        cfg = d["cfg"]
        ns  = np.array([e[0] for e in d["entries"]], dtype=float)
        qps = np.array([e[1] / 1e3 for e in d["entries"]], dtype=float)
        sd  = np.array([e[2] / 1e3 for e in d["entries"]], dtype=float)

        # 滑らかな補間曲線 (メイン)
        xs, ys = _smooth_curve(ns, qps)
        ax.plot(xs, ys, "-", lw=2.0, color=cfg["color"], label=cfg["label"], alpha=0.95)
        # 実測点は小さいマーカーで場所だけ示す (±1σ エラーバー)
        ax.errorbar(ns, qps, yerr=sd, fmt="o", ms=3, color=cfg["color"],
                    capsize=2, alpha=0.6, zorder=3, elinewidth=0.7)

        # master baseline as horizontal line
        if d["master"]:
            m_qps = d["master"][0] / 1e3
            ax.axhline(m_qps, color=cfg["color"], ls=":", lw=1.0, alpha=0.7)
            ax.text(202, m_qps, f" master {m_qps:.0f}", color=cfg["color"],
                    fontsize=8, va="center")
        # peak marker (実測ピーク位置)
        peak_i = int(np.argmax(qps))
        ax.scatter([ns[peak_i]], [qps[peak_i]], color=cfg["color"], s=110,
                   marker="*", zorder=6, edgecolor="black", linewidth=0.8)
        ax.annotate(f"N={int(ns[peak_i])}",
                    xy=(ns[peak_i], qps[peak_i]),
                    xytext=(6, 8), textcoords="offset points",
                    fontsize=9, color=cfg["color"], weight="bold")

    ax.set_xlabel("PAUSE per round (N)", fontsize=12)
    ax.set_ylabel("QPS [kQPS]", fontsize=12)
    ax.set_title("QPS vs N — 4 archs (production)", fontsize=13)
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    ax.legend(loc="lower center", fontsize=10, ncol=1)
    ax.text(0.02, 0.02, FIG_META, transform=ax.transAxes,
            fontsize=7.5, color="gray", va="bottom", alpha=0.8)
    fig.tight_layout()
    fig.savefig(outpath, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {outpath}")


def plot_qps_normalized(data, outpath):
    fig, ax = plt.subplots(figsize=(9.5, 5.5))
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    for arch, d in data.items():
        cfg = d["cfg"]
        if not d["master"]:
            continue
        m = d["master"][0]
        ns   = np.array([e[0] for e in d["entries"]], dtype=float)
        norm = np.array([e[1] / m for e in d["entries"]], dtype=float)

        xs, ys = _smooth_curve(ns, norm)
        ax.plot(xs, ys, "-", lw=2.0, color=cfg["color"], label=cfg["label"], alpha=0.95)
        ax.scatter(ns, norm, s=14, color=cfg["color"], alpha=0.55, zorder=3)

        peak_i = int(np.argmax(norm))
        ax.scatter([ns[peak_i]], [norm[peak_i]], color=cfg["color"], s=110,
                   marker="*", zorder=6, edgecolor="black", linewidth=0.8)
        ax.annotate(f"N={int(ns[peak_i])}\n×{norm[peak_i]:.2f}",
                    xy=(ns[peak_i], norm[peak_i]),
                    xytext=(6, 8), textcoords="offset points",
                    fontsize=9, color=cfg["color"], weight="bold")

    ax.axhline(1.0, color="black", ls="--", lw=0.8, alpha=0.5, label="master baseline (=1.0)")
    ax.set_xlabel("PAUSE per round (N)", fontsize=12)
    ax.set_ylabel("QPS / master QPS", fontsize=12)
    ax.set_title("Normalized QPS (vs pthread_mutex baseline) — 4 archs (production)", fontsize=13)
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    ax.legend(loc="lower center", fontsize=10)
    ax.text(0.02, 0.02, FIG_META, transform=ax.transAxes,
            fontsize=7.5, color="gray", va="bottom", alpha=0.8)
    fig.tight_layout()
    fig.savefig(outpath, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {outpath}")


def plot_qps_pause_budget(data, outpath):
    """x軸: total PAUSE budget (N × PAUSE cycle 数)。アーキ間の hardware time で正規化。"""
    fig, ax = plt.subplots(figsize=(9.5, 5.5))
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    for arch, d in data.items():
        cfg = d["cfg"]
        pause_cy = cfg["pause_cy"]
        ns      = np.array([e[0] for e in d["entries"]], dtype=float)
        qps     = np.array([e[1] / 1e3 for e in d["entries"]], dtype=float)
        budgets = ns * pause_cy

        xs, ys = _smooth_curve(budgets, qps)
        ax.plot(xs, ys, "-", lw=2.0, color=cfg["color"], label=cfg["label"], alpha=0.95)
        ax.scatter(budgets, qps, s=14, color=cfg["color"], alpha=0.55, zorder=3)

        peak_i = int(np.argmax(qps))
        ax.scatter([budgets[peak_i]], [qps[peak_i]], color=cfg["color"], s=110,
                   marker="*", zorder=6, edgecolor="black", linewidth=0.8)
        ax.annotate(f"N={int(ns[peak_i])}\n{budgets[peak_i]:.0f}cy",
                    xy=(budgets[peak_i], qps[peak_i]),
                    xytext=(8, 8), textcoords="offset points",
                    fontsize=9, color=cfg["color"], weight="bold")

    ax.set_xlabel("PAUSE budget per spin round [cycles]  (= N × PAUSE cy)", fontsize=12)
    ax.set_ylabel("QPS [kQPS]", fontsize=12)
    ax.set_title("QPS vs PAUSE budget (x-axis normalized) — 4 archs (production)", fontsize=13)
    ax.set_xlim(0, 2500)
    ax.grid(axis="y", linestyle=":", alpha=0.4)
    ax.legend(loc="lower right", fontsize=10)
    ax.text(0.02, 0.02, FIG_META, transform=ax.transAxes,
            fontsize=7.5, color="gray", va="bottom", alpha=0.8)
    fig.tight_layout()
    fig.savefig(outpath, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {outpath}")


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    os.makedirs(OUTDIR, exist_ok=True)
    data = _load_all()
    if len(data) < 2:
        raise SystemExit("[ERROR] need at least 2 archs data")

    plot_qps_abs         (data, os.path.join(OUTDIR, "qps_comparison_production_n30.pdf"))
    plot_qps_normalized  (data, os.path.join(OUTDIR, "qps_normalized_production_n30.pdf"))
    plot_qps_pause_budget(data, os.path.join(OUTDIR, "qps_pause_budget_production_n30.pdf"))

    print("\nDone.")


if __name__ == "__main__":
    main()
