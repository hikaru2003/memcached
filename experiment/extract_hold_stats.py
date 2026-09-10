#!/usr/bin/env python3
"""
Usage:
    python3 experiment/extract_hold_stats.py --dir experiment/results/hold_YYYYMMDD_HHMMSS

Description:
    hold time sweep の各 N ディレクトリから hold_samples_thread*.bin を読み込み、
    統計 (min/mean/p50/p90/p95/p99/p999/max) を計算して CSV に出力する。
    サイクル単位で出力する (PAUSE cy と直接比較するため、us 換算しない)。
    参考として us 列も付随する。

Output:
    <dir>/hold_summary.csv
      label, ppr, mean_qps, n_samples,
      min_cy, mean_cy, p50_cy, p90_cy, p95_cy, p99_cy, p999_cy, max_cy,
      p50_us, p99_us  (参考、TSC MHz 前提)
"""
import argparse
import csv
import glob
import os
import re
import sys
import numpy as np


def load_samples(dir_n):
    files = sorted(glob.glob(os.path.join(dir_n, "hold_samples_thread*.bin")))
    arrs = [np.fromfile(f, dtype=np.uint64) for f in files]
    if not arrs:
        return np.array([], dtype=np.uint64)
    return np.concatenate(arrs)


def load_qps(dir_n):
    stats = os.path.join(dir_n, "stats.txt")
    if not os.path.exists(stats):
        return None
    with open(stats) as f:
        for line in f:
            if line.startswith("mean_qps="):
                return int(line.split("=", 1)[1].strip())
    return None


def compute_stats(samples):
    if samples.size == 0:
        return None
    percentiles = [50, 90, 95, 99, 99.9]
    p = np.percentile(samples, percentiles)
    return {
        "n": int(samples.size),
        "min": int(samples.min()),
        "mean": float(samples.mean()),
        "p50": float(p[0]),
        "p90": float(p[1]),
        "p95": float(p[2]),
        "p99": float(p[3]),
        "p999": float(p[4]),
        "max": int(samples.max()),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--tsc-mhz", type=float, default=2100.0)
    args = ap.parse_args()

    result_dir = args.dir
    if not os.path.isdir(result_dir):
        sys.exit(f"[ERROR] not a directory: {result_dir}")

    # Support two directory naming conventions:
    #   N<n>       (N sweep, single MC_THREADS)
    #   N<n>_T<t>  (Phase 2: N × MC_THREADS sweep)
    n_dirs = []
    for d in os.listdir(result_dir):
        m2 = re.match(r"^N(\d+)_T(\d+)$", d)
        if m2:
            n_dirs.append((int(m2.group(2)), int(m2.group(1)), d))  # sort by T then N
            continue
        m1 = re.match(r"^N(\d+)$", d)
        if m1:
            n_dirs.append((-1, int(m1.group(1)), d))
    n_dirs.sort()

    if not n_dirs:
        sys.exit(f"[ERROR] no N<x> or N<x>_T<y> subdirectories found in {result_dir}")

    csv_path = os.path.join(result_dir, "hold_summary.csv")
    cy_to_us = 1.0 / args.tsc_mhz

    with open(csv_path, "w", newline="") as fout:
        w = csv.writer(fout)
        w.writerow([
            "label", "ppr", "mc_threads", "mean_qps", "n_samples",
            "min_cy", "mean_cy", "p50_cy", "p90_cy", "p95_cy", "p99_cy", "p999_cy", "max_cy",
            "p50_us", "p99_us",
        ])
        for T, ppr, name in n_dirs:
            dir_n = os.path.join(result_dir, name)
            samples = load_samples(dir_n)
            stats = compute_stats(samples)
            qps = load_qps(dir_n)
            if stats is None:
                print(f"[WARN] {name}: no samples")
                continue
            t_str = str(T) if T > 0 else ""
            w.writerow([
                name, ppr, t_str, qps if qps is not None else "",
                stats["n"],
                stats["min"], f"{stats['mean']:.1f}",
                f"{stats['p50']:.1f}", f"{stats['p90']:.1f}", f"{stats['p95']:.1f}",
                f"{stats['p99']:.1f}", f"{stats['p999']:.1f}", stats["max"],
                f"{stats['p50']*cy_to_us:.4f}", f"{stats['p99']*cy_to_us:.4f}",
            ])
            t_label = f"T{T}" if T > 0 else "  "
            print(f"[OK] {name:10s} N={ppr:4d} {t_label:3s}  QPS={qps or 'N/A':>7}  n={stats['n']:>8}  "
                  f"p50={stats['p50']:6.0f}cy  mean={stats['mean']:6.0f}cy  "
                  f"p99={stats['p99']:7.0f}cy  p999={stats['p999']:8.0f}cy")

    print(f"\n[write] {csv_path}")


if __name__ == "__main__":
    main()
