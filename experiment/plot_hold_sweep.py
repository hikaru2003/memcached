#!/usr/bin/env python3
"""
Usage:
    python3 experiment/plot_hold_sweep.py \
        --mixed experiment/results/archive/20260910/misc/hold_20260909_224442 \
        --get100 experiment/results/archive/20260910/misc/hold_20260910_111927 \
        --outdir experiment/results/plots/v3

Description:
    hold time sweep の結果を PDF にプロットする。SET/GET 混合と GET 100% を比較する。

    出力 PDF:
      hold_qps_vs_N.pdf              - QPS vs N (混合 vs GET100 の 2 線)
      hold_cs_percentiles.pdf        - CS 長 (p50/mean/p99/p999) の 4 サブプロット
      hold_qps_cs_2axis_get100.pdf   - GET 100% の QPS と p99 CS 長を 2 軸プロット
      hold_get100_overview.pdf       - GET 100% 全体像 (QPS + p50/p99/p999)

Parameters:
    --mixed   : Phase 1 (SET/GET 混合) の hold sweep 結果ディレクトリ
    --get100  : GET 100% の hold sweep 結果ディレクトリ
    --outdir  : PDF 出力先 (default: experiment/results/plots/v3)

Prerequisites:
    numpy, matplotlib
    extract_hold_stats.py で hold_summary.csv を作成しておく
"""
import argparse
import csv
import os

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
                "qps": int(row["mean_qps"]) if row["mean_qps"] else 0,
                "p50": float(row["p50_cy"]),
                "p90": float(row["p90_cy"]),
                "p95": float(row["p95_cy"]),
                "p99": float(row["p99_cy"]),
                "p999": float(row["p999_cy"]),
                "mean": float(row["mean_cy"]),
            })
    rows.sort(key=lambda x: x["ppr"])
    return rows


def plot_qps_compare(mixed, get100, out_pdf):
    fig, ax = plt.subplots(figsize=(8, 5))
    n_mixed = [r["ppr"] for r in mixed]
    q_mixed = [r["qps"] / 1000.0 for r in mixed]
    peak_i_m = int(np.argmax(q_mixed))

    n_get = [r["ppr"] for r in get100]
    q_get = [r["qps"] / 1000.0 for r in get100]
    peak_i_g = int(np.argmax(q_get))

    ax.plot(n_mixed, q_mixed, marker="o", ms=4, label="SET/GET 50/50 (Phase 1)", color="tab:orange")
    ax.plot(n_get, q_get, marker="s", ms=4, label="GET 100%", color="tab:green")

    ax.axvline(n_mixed[peak_i_m], color="tab:orange", ls="--", alpha=0.5,
               label=f"mixed peak: N={n_mixed[peak_i_m]}")
    ax.axvline(n_get[peak_i_g], color="tab:green", ls="--", alpha=0.5,
               label=f"GET100 peak: N={n_get[peak_i_g]}")

    ax.set_xlabel("PAUSE per round (N)")
    ax.set_ylabel("QPS (kQPS)")
    ax.set_title("QPS vs N: SET/GET 50/50 vs GET 100%  (skylake ann, T=4)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="best")
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def plot_cs_percentiles_compare(mixed, get100, out_pdf):
    fig, axes = plt.subplots(2, 2, figsize=(11, 8))
    metrics = [("p50", "p50 (median)"), ("mean", "mean"), ("p99", "p99"), ("p999", "p999")]

    n_mixed = [r["ppr"] for r in mixed]
    n_get = [r["ppr"] for r in get100]

    for ax, (key, label) in zip(axes.flat, metrics):
        v_mixed = [r[key] for r in mixed]
        v_get = [r[key] for r in get100]
        ax.plot(n_mixed, v_mixed, marker="o", ms=4, label="SET/GET 50/50", color="tab:orange")
        ax.plot(n_get, v_get, marker="s", ms=4, label="GET 100%", color="tab:green")
        ax.set_xlabel("PAUSE per round (N)")
        ax.set_ylabel(f"CS length ({label}) [cy]")
        ax.set_title(f"CS length {label} vs N")
        ax.set_yscale("log")
        ax.grid(True, which="both", alpha=0.3)
        ax.legend(loc="best", fontsize=9)

    fig.suptitle("CS length percentiles: SET/GET 50/50 vs GET 100%  (skylake ann, T=4)")
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def plot_qps_cs_2axis(get100, out_pdf, tsc_mhz=2100.0):
    n = [r["ppr"] for r in get100]
    q = [r["qps"] / 1000.0 for r in get100]
    p99 = [r["p99"] for r in get100]
    peak_i = int(np.argmax(q))

    fig, ax1 = plt.subplots(figsize=(8, 5))
    color1 = "tab:green"
    ax1.plot(n, q, marker="o", ms=4, color=color1, label="QPS")
    ax1.set_xlabel("PAUSE per round (N)")
    ax1.set_ylabel("QPS (kQPS)", color=color1)
    ax1.tick_params(axis="y", labelcolor=color1)
    ax1.grid(True, alpha=0.3)
    ax1.axvline(n[peak_i], color="gray", ls="--", alpha=0.6,
                label=f"peak: N={n[peak_i]}, QPS={q[peak_i]:.0f}k")

    ax2 = ax1.twinx()
    color2 = "tab:red"
    ax2.plot(n, p99, marker="s", ms=4, color=color2, label="p99 CS length")
    ax2.set_ylabel("CS length p99 (cycles)", color=color2)
    ax2.tick_params(axis="y", labelcolor=color2)
    ax2.set_yscale("log")

    ax1.set_title(f"GET 100%: QPS peak at N={n[peak_i]}, CS length monotonic decrease  (skylake ann, T=4)")
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="best", fontsize=9)
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def plot_get100_overview(get100, out_pdf):
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))
    n = [r["ppr"] for r in get100]

    # Left: QPS
    q = [r["qps"] / 1000.0 for r in get100]
    peak_i = int(np.argmax(q))
    ax1.plot(n, q, marker="o", ms=4, color="tab:green")
    ax1.axvline(n[peak_i], color="gray", ls="--", alpha=0.6,
                label=f"peak: N={n[peak_i]} ({q[peak_i]:.0f} kQPS)")
    ax1.set_xlabel("PAUSE per round (N)")
    ax1.set_ylabel("QPS (kQPS)")
    ax1.set_title("QPS vs N (GET 100%)")
    ax1.grid(True, alpha=0.3)
    ax1.legend(loc="best")

    # Right: CS length percentiles
    p50 = [r["p50"] for r in get100]
    mean = [r["mean"] for r in get100]
    p99 = [r["p99"] for r in get100]
    p999 = [r["p999"] for r in get100]
    ax2.plot(n, p50, marker="o", ms=4, label="p50", color="tab:blue")
    ax2.plot(n, mean, marker="d", ms=4, label="mean", color="tab:purple")
    ax2.plot(n, p99, marker="s", ms=4, label="p99", color="tab:orange")
    ax2.plot(n, p999, marker="^", ms=4, label="p999", color="tab:red")
    ax2.set_xlabel("PAUSE per round (N)")
    ax2.set_ylabel("CS length (cycles)")
    ax2.set_title("CS length percentiles (GET 100%)")
    ax2.set_yscale("log")
    ax2.grid(True, which="both", alpha=0.3)
    ax2.legend(loc="best", fontsize=9)

    fig.suptitle("GET 100% overview  (skylake ann, T=4)")
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def load_raw_samples(dir_root, ppr):
    """Load raw uint64 samples from N<ppr>/hold_samples_thread*.bin"""
    import glob
    files = sorted(glob.glob(os.path.join(dir_root, f"N{ppr}", "hold_samples_thread*.bin")))
    arrs = [np.fromfile(f, dtype=np.uint64) for f in files]
    if not arrs:
        return np.array([], dtype=np.uint64)
    return np.concatenate(arrs)


def plot_cdf_compare(mixed_dir, get100_dir, out_pdf, samples_to_use=200000):
    """分布形状の比較 CDF。SET/GET 混合の peak N (N=5) と GET 100% peak N (N=20) を重ねる"""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

    configs = [
        # (dir, N, workload_label, color)
        (mixed_dir, 0, "SET/GET N=0", "tab:orange"),
        (mixed_dir, 5, "SET/GET N=5 (peak)", "tab:red"),
        (mixed_dir, 200, "SET/GET N=200", "tab:brown"),
        (get100_dir, 0, "GET100 N=0", "tab:green"),
        (get100_dir, 20, "GET100 N=20 (peak)", "tab:blue"),
        (get100_dir, 200, "GET100 N=200", "tab:cyan"),
    ]

    for dir_root, ppr, label, color in configs:
        s = load_raw_samples(dir_root, ppr)
        if s.size == 0:
            print(f"[SKIP] {label}: no samples")
            continue
        if s.size > samples_to_use:
            idx = np.linspace(0, s.size - 1, samples_to_use, dtype=np.int64)
            s_ds = np.sort(s[idx])
        else:
            s_ds = np.sort(s)
        cdf = np.arange(1, s_ds.size + 1) / s_ds.size

        # Left: log scale x (全体像)
        ax1.plot(s_ds, cdf, label=label, color=color, lw=1.5)
        # Right: linear scale x (低cy側を拡大、tail は切る)
        ax2.plot(s_ds, cdf, label=label, color=color, lw=1.5)

    ax1.set_xscale("log")
    ax1.set_xlabel("CS length (cycles, log scale)")
    ax1.set_ylabel("CDF")
    ax1.set_title("CDF (log x, full range)")
    ax1.grid(True, which="both", alpha=0.3)
    ax1.legend(loc="lower right", fontsize=9)
    ax1.set_ylim(0, 1.01)

    ax2.set_xlim(0, 500)
    ax2.set_xlabel("CS length (cycles, linear 0-500)")
    ax2.set_ylabel("CDF")
    ax2.set_title("CDF (linear x, zoomed)")
    ax2.grid(True, alpha=0.3)
    ax2.legend(loc="lower right", fontsize=9)
    ax2.set_ylim(0, 1.01)

    fig.suptitle("CS length CDF: SET/GET 50/50 vs GET 100%  (skylake ann, T=4)")
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def plot_p50_mean_overlay(mixed, get100, out_pdf):
    """p50 と mean を同じサブプロットに重ねる (光の気づきを可視化)"""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

    # Left: SET/GET 混合
    n = [r["ppr"] for r in mixed]
    p50 = [r["p50"] for r in mixed]
    mean = [r["mean"] for r in mixed]
    ax1.plot(n, p50, marker="o", ms=4, label="p50 (median)", color="tab:blue")
    ax1.plot(n, mean, marker="d", ms=4, label="mean", color="tab:purple")
    ax1.fill_between(n, p50, mean, alpha=0.15, color="tab:red", label="diff (tail effect)")
    ax1.set_xlabel("PAUSE per round (N)")
    ax1.set_ylabel("CS length (cycles)")
    ax1.set_title("SET/GET 50/50: mean >> p50\n(heavy tail lifts mean)")
    ax1.set_yscale("log")
    ax1.grid(True, which="both", alpha=0.3)
    ax1.legend(loc="best", fontsize=9)

    # Right: GET 100%
    n = [r["ppr"] for r in get100]
    p50 = [r["p50"] for r in get100]
    mean = [r["mean"] for r in get100]
    ax2.plot(n, p50, marker="o", ms=4, label="p50 (median)", color="tab:blue")
    ax2.plot(n, mean, marker="d", ms=4, label="mean", color="tab:purple")
    ax2.fill_between(n, [min(a, b) for a, b in zip(p50, mean)],
                     [max(a, b) for a, b in zip(p50, mean)],
                     alpha=0.15, color="tab:green", label="diff (near zero)")
    ax2.set_xlabel("PAUSE per round (N)")
    ax2.set_ylabel("CS length (cycles)")
    ax2.set_title("GET 100%: mean ~= p50 (sometimes mean < p50)\n(short tail, near-symmetric distribution)")
    ax2.grid(True, alpha=0.3)
    ax2.legend(loc="best", fontsize=9)

    fig.suptitle("p50 vs mean relationship: distribution shape difference  (skylake ann, T=4)")
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mixed", required=True, help="SET/GET 混合の hold sweep ディレクトリ")
    ap.add_argument("--get100", required=True, help="GET 100% の hold sweep ディレクトリ")
    ap.add_argument("--outdir", default="experiment/results/plots/v3")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    mixed_csv = os.path.join(args.mixed, "hold_summary.csv")
    get100_csv = os.path.join(args.get100, "hold_summary.csv")
    if not os.path.exists(mixed_csv):
        raise SystemExit(f"[ERROR] {mixed_csv} not found (run extract_hold_stats.py first)")
    if not os.path.exists(get100_csv):
        raise SystemExit(f"[ERROR] {get100_csv} not found (run extract_hold_stats.py first)")

    mixed = load_summary(mixed_csv)
    get100 = load_summary(get100_csv)

    plot_qps_compare(mixed, get100, os.path.join(args.outdir, "hold_qps_vs_N.pdf"))
    plot_cs_percentiles_compare(mixed, get100, os.path.join(args.outdir, "hold_cs_percentiles.pdf"))
    plot_qps_cs_2axis(get100, os.path.join(args.outdir, "hold_qps_cs_2axis_get100.pdf"))
    plot_get100_overview(get100, os.path.join(args.outdir, "hold_get100_overview.pdf"))
    plot_p50_mean_overlay(mixed, get100, os.path.join(args.outdir, "hold_p50_mean_overlay.pdf"))
    plot_cdf_compare(args.mixed, args.get100, os.path.join(args.outdir, "hold_cs_cdf_compare.pdf"))


if __name__ == "__main__":
    main()
