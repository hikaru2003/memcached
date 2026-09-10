#!/usr/bin/env python3
"""
Usage:
    python3 experiment/plot_unlock_sweep.py \
        --dir experiment/results/unlock_YYYYMMDD_HHMMSS \
        --outdir experiment/results/plots/v3

Description:
    unlock latency sweep の結果を PDF プロットに可視化する。
      1. unlock_latency_vs_N.pdf   - p50/p99/p999 の unlock latency vs N
      2. unlock_qps_vs_N.pdf       - QPS vs N (山形参照)
      3. unlock_qps_latency_2axis.pdf - QPS と unlock latency (p99) の2軸プロット
      4. unlock_cdf_selected_N.pdf - N=0/4/30/200 の CDF 重ね書き

Parameters:
    --dir      : unlock sweep 結果ディレクトリ
    --outdir   : PDF 出力先 (default: experiment/results/plots/v3)
    --tsc-mhz  : TSC 周波数 (default: 2100)

Output:
    上記4種の PDF ファイルを --outdir に出力する。

Prerequisites:
    numpy, matplotlib
    先に extract_unlock_stats.py を実行して unlock_summary.csv を生成しておく。
"""
import argparse
import csv
import glob
import os
import re

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def load_summary(path):
    rows = []
    with open(path) as f:
        r = csv.DictReader(f)
        for row in r:
            rows.append({
                "ppr": int(row["ppr"]),
                "qps": int(row["mean_qps"]) if row["mean_qps"] else None,
                "p50_us": float(row["p50_us"]),
                "p99_us": float(row["p99_us"]),
                "p999_us": float(row["p999_us"]),
                "mean_us": float(row["mean_us"]),
            })
    rows.sort(key=lambda x: x["ppr"])
    return rows


def load_samples_us(dir_n, tsc_mhz):
    files = sorted(glob.glob(os.path.join(dir_n, "unlock_samples_thread*.bin")))
    arrs = [np.fromfile(f, dtype=np.uint64) for f in files]
    if not arrs:
        return np.array([])
    all_cy = np.concatenate(arrs)
    return all_cy.astype(np.float64) / tsc_mhz  # cy -> us


def plot_unlock_vs_N(rows, out_pdf):
    n = [r["ppr"] for r in rows]
    p50 = [r["p50_us"] for r in rows]
    p99 = [r["p99_us"] for r in rows]
    p999 = [r["p999_us"] for r in rows]

    fig, ax = plt.subplots(figsize=(7, 4.5))
    mean = [r["mean_us"] for r in rows]
    ax.plot(n, p50, marker="o", ms=5, lw=1.8, label="p50", color="tab:blue")
    ax.plot(n, mean, marker="d", ms=5, lw=2.2, label="mean", color="tab:purple")
    ax.plot(n, p99, marker="s", ms=5, lw=1.8, label="p99", color="tab:orange")
    ax.plot(n, p999, marker="^", ms=5, lw=1.8, label="p999", color="tab:red")
    ax.set_xlabel("PAUSE per round (N)", fontsize=13)
    ax.set_ylabel("unlock latency (us)", fontsize=13)
    ax.set_title("unlock latency vs N  (skylake ann, MC_THREADS=4)", fontsize=13)
    ax.set_yscale("log")
    from matplotlib.ticker import FuncFormatter
    ax.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"{x:g}"))
    ax.yaxis.set_minor_formatter(FuncFormatter(lambda x, _: ""))
    ax.set_yticks([0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0])
    ax.tick_params(axis="both", labelsize=12)
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(fontsize=12)
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def plot_qps_vs_N(rows, out_pdf):
    n = [r["ppr"] for r in rows]
    qps = [r["qps"] / 1000.0 if r["qps"] else 0 for r in rows]
    peak_i = int(np.argmax(qps))

    fig, ax = plt.subplots(figsize=(7, 4.5))
    ax.plot(n, qps, marker="o", ms=4, color="tab:green")
    ax.axvline(n[peak_i], color="gray", ls="--", alpha=0.5,
               label=f"peak at N={n[peak_i]} ({qps[peak_i]:.0f} kQPS)")
    ax.set_xlabel("PAUSE per round (N)")
    ax.set_ylabel("QPS (kQPS)")
    ax.set_title("QPS vs N  (skylake ann, MC_THREADS=4)")
    ax.grid(True, alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def plot_qps_latency_2axis(rows, out_pdf):
    n = [r["ppr"] for r in rows]
    qps = [r["qps"] / 1000.0 if r["qps"] else 0 for r in rows]
    mean = [r["mean_us"] for r in rows]
    peak_i = int(np.argmax(qps))

    fig, ax1 = plt.subplots(figsize=(9, 5.5))
    color1 = "tab:green"
    ax1.plot(n, qps, marker="o", ms=6, lw=2.0, color=color1, label="QPS")
    ax1.set_xlabel("PAUSE per round (N)", fontsize=13)
    ax1.set_ylabel("QPS (kQPS)", color=color1, fontsize=13)
    ax1.tick_params(axis="y", labelcolor=color1, labelsize=12)
    ax1.tick_params(axis="x", labelsize=12)
    ax1.grid(True, alpha=0.3)
    ax1.axvline(n[peak_i], color="gray", ls="--", alpha=0.5,
                label=f"QPS peak: N={n[peak_i]}")

    # 3 段階の背景色分け (Stage 1: 急上昇, Stage 2: plateau, Stage 3: 緩やかな低下)
    ax1.axvspan(-2, n[peak_i], alpha=0.08, color="green", label=None)
    ax1.axvspan(n[peak_i], 10, alpha=0.08, color="yellow", label=None)
    ax1.axvspan(10, 205, alpha=0.08, color="red", label=None)

    ax2 = ax1.twinx()
    color2 = "tab:purple"
    ax2.plot(n, mean, marker="d", ms=6, lw=2.0, color=color2, label="unlock mean")
    ax2.set_ylabel("unlock latency mean (us)", color=color2, fontsize=13)
    ax2.tick_params(axis="y", labelcolor=color2, labelsize=12)
    ax2.set_yscale("log")
    from matplotlib.ticker import FuncFormatter
    ax2.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"{x:g}"))
    ax2.yaxis.set_minor_formatter(FuncFormatter(lambda x, _: ""))
    ax2.set_yticks([0.05, 0.07, 0.1, 0.15, 0.2, 0.3])

    ax1.set_title(f"QPS and unlock latency (mean): 3 stages (skylake ann, MC_THREADS=4)\n"
                  f"green=Stage1 (rapid rise), yellow=Stage2 (plateau), red=Stage3 (slow decline)",
                  fontsize=12)
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="lower right", fontsize=11)
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def plot_cdf_selected(dir_root, tsc_mhz, out_pdf, selected=(0, 4, 30, 200)):
    fig, ax = plt.subplots(figsize=(7, 4.5))
    colors = ["tab:blue", "tab:green", "tab:orange", "tab:red"]
    for i, ppr in enumerate(selected):
        dir_n = os.path.join(dir_root, f"N{ppr}")
        if not os.path.isdir(dir_n):
            print(f"[SKIP] {dir_n} not found")
            continue
        s_us = load_samples_us(dir_n, tsc_mhz)
        if s_us.size == 0:
            continue
        # downsample to keep plot lightweight
        if s_us.size > 200000:
            idx = np.linspace(0, s_us.size - 1, 200000, dtype=np.int64)
            s_us_ds = np.sort(s_us[idx])
        else:
            s_us_ds = np.sort(s_us)
        cdf = np.arange(1, s_us_ds.size + 1) / s_us_ds.size
        ax.plot(s_us_ds, cdf, label=f"N={ppr}", color=colors[i % len(colors)], lw=1.5)

    ax.set_xscale("log")
    ax.set_xlabel("unlock latency (μs)")
    ax.set_ylabel("CDF")
    ax.set_title("unlock latency CDF (selected N)  (skylake ann, MC_THREADS=4)")
    ax.grid(True, which="both", alpha=0.3)
    ax.set_ylim(0, 1.01)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="unlock sweep result directory")
    ap.add_argument("--outdir", default="experiment/results/plots/v3", help="PDF output directory")
    ap.add_argument("--tsc-mhz", type=float, default=2100.0)
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    summary_csv = os.path.join(args.dir, "unlock_summary.csv")
    if not os.path.exists(summary_csv):
        raise SystemExit(f"[ERROR] {summary_csv} not found. Run extract_unlock_stats.py first.")

    rows = load_summary(summary_csv)
    plot_unlock_vs_N(rows, os.path.join(args.outdir, "unlock_latency_vs_N.pdf"))
    plot_qps_vs_N(rows, os.path.join(args.outdir, "unlock_qps_vs_N.pdf"))
    plot_qps_latency_2axis(rows, os.path.join(args.outdir, "unlock_qps_latency_2axis.pdf"))
    plot_cdf_selected(args.dir, args.tsc_mhz,
                      os.path.join(args.outdir, "unlock_cdf_selected_N.pdf"))


if __name__ == "__main__":
    main()
