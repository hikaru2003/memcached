#!/usr/bin/env python3
"""
Usage:
    python3 experiment/extract_unlock_stats.py --dir experiment/results/unlock_YYYYMMDD_HHMMSS

Description:
    unlock latency sweep の各 N ディレクトリから unlock_samples_thread*.bin を読み込み、
    統計 (min/mean/p50/p90/p95/p99/p999/max) を計算して CSV に出力する。
    TSC 周波数は run_info.md に記載がなければ既定 2100 MHz を使う。

Output:
    <dir>/unlock_summary.csv  (label, ppr, mean_qps, n_samples,
                               min_cy, mean_cy, p50_cy, p90_cy, p95_cy, p99_cy, p999_cy, max_cy,
                               min_us, mean_us, p50_us, p90_us, p95_us, p99_us, p999_us, max_us)
"""
import argparse
import csv
import glob
import os
import re
import sys
import numpy as np


def load_samples(dir_n):
    files = sorted(glob.glob(os.path.join(dir_n, "unlock_samples_thread*.bin")))
    arrs = []
    for f in files:
        arr = np.fromfile(f, dtype=np.uint64)
        arrs.append(arr)
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
    ap.add_argument("--dir", required=True, help="unlock sweep result directory")
    ap.add_argument("--tsc-mhz", type=float, default=2100.0, help="TSC frequency in MHz (default 2100 for Silver 4110 base)")
    args = ap.parse_args()

    result_dir = args.dir
    if not os.path.isdir(result_dir):
        sys.exit(f"[ERROR] not a directory: {result_dir}")

    n_dirs = []
    for d in os.listdir(result_dir):
        m = re.match(r"^N(\d+)$", d)
        if m:
            n_dirs.append((int(m.group(1)), d))
    n_dirs.sort()

    if not n_dirs:
        sys.exit(f"[ERROR] no N<x> subdirectories found in {result_dir}")

    csv_path = os.path.join(result_dir, "unlock_summary.csv")
    cy_to_us = 1.0 / args.tsc_mhz  # 1 cycle = 1/MHz μs

    with open(csv_path, "w", newline="") as fout:
        w = csv.writer(fout)
        w.writerow([
            "label", "ppr", "mean_qps", "n_samples",
            "min_cy", "mean_cy", "p50_cy", "p90_cy", "p95_cy", "p99_cy", "p999_cy", "max_cy",
            "min_us", "mean_us", "p50_us", "p90_us", "p95_us", "p99_us", "p999_us", "max_us",
        ])
        for ppr, name in n_dirs:
            dir_n = os.path.join(result_dir, name)
            samples = load_samples(dir_n)
            stats = compute_stats(samples)
            qps = load_qps(dir_n)
            if stats is None:
                print(f"[WARN] {name}: no samples")
                continue
            row_cy = [stats["min"], stats["mean"], stats["p50"], stats["p90"],
                      stats["p95"], stats["p99"], stats["p999"], stats["max"]]
            row_us = [v * cy_to_us for v in row_cy]
            w.writerow([
                name, ppr, qps if qps is not None else "",
                stats["n"],
                *[f"{v:.2f}" if isinstance(v, float) else v for v in row_cy],
                *[f"{v:.4f}" for v in row_us],
            ])
            print(f"[OK] {name:5s}  ppr={ppr:4d}  QPS={qps or 'N/A':>7}  n={stats['n']:>8}  "
                  f"p50={row_us[2]:.3f}us  p99={row_us[5]:.3f}us  p999={row_us[6]:.3f}us")

    print(f"\n[write] {csv_path}")


if __name__ == "__main__":
    main()
