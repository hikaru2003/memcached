#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/extract_wait_stats.py --dir experiment/results/wait_dist_YYYYMMDD_HHMMSS
#
# Description:
#   wait_dist 実験結果ディレクトリ内の .bin ファイルからパーセンタイル統計を抽出し、
#   wait_summary.csv として保存する。グラフ生成は行わない（ann サーバ側で実施）。
#
# Parameters:
#   --dir DIR      wait_dist 実験結果ディレクトリ
#   --tsc-mhz MHZ TSC周波数 MHz（省略で /proc/cpuinfo から自動取得）
#   --out PATH     出力 CSV パス（省略で <DIR>/wait_summary.csv）
#
# Output:
#   <DIR>/wait_summary.csv  — 条件ごとのパーセンタイル統計（µs）
#     columns: condition, n_samples, tsc_mhz,
#              min_us, p10_us, p25_us, p50_us, p75_us, p90_us, p95_us, p99_us, p999_us, max_us
#
# Prerequisites:
#   pip install numpy

import argparse
import csv
import glob
import os
import re
import sys

import numpy as np


def detect_tsc_mhz():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if "cpu MHz" in line:
                    return float(line.split(":")[1].strip())
    except Exception:
        pass
    return 2400.0


def load_condition(dirpath):
    """dirpath 内の wait_samples_thread*.bin を全スレッド合算して返す（cycles）。"""
    files = sorted(glob.glob(os.path.join(dirpath, "wait_samples_thread*.bin")))
    if not files:
        return None
    return np.concatenate([np.fromfile(f, dtype=np.uint64) for f in files])


def discover_conditions(base_dir):
    """base_dir 直下のサブディレクトリを条件として列挙する。"""
    entries = sorted(os.listdir(base_dir))
    conditions = []
    for name in entries:
        path = os.path.join(base_dir, name)
        if os.path.isdir(path) and glob.glob(os.path.join(path, "wait_samples_thread*.bin")):
            conditions.append((name, path))
    return conditions


def condition_sort_key(name):
    if name == "master":
        return -1
    m = re.match(r"N(\d+)$", name)
    return int(m.group(1)) if m else 9999


def extract_stats(samples_cycles, tsc_mhz):
    us = samples_cycles.astype(np.float64) / tsc_mhz
    pcts = np.percentile(us, [0, 10, 25, 50, 75, 90, 95, 99, 99.9, 100])
    return {
        "n_samples": len(us),
        "min_us":    pcts[0],
        "p10_us":    pcts[1],
        "p25_us":    pcts[2],
        "p50_us":    pcts[3],
        "p75_us":    pcts[4],
        "p90_us":    pcts[5],
        "p95_us":    pcts[6],
        "p99_us":    pcts[7],
        "p999_us":   pcts[8],
        "max_us":    pcts[9],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir",     required=True, help="wait_dist 実験結果ディレクトリ")
    ap.add_argument("--tsc-mhz", type=float,    help="TSC周波数 MHz（省略で自動取得）")
    ap.add_argument("--out",                     help="出力 CSV パス")
    args = ap.parse_args()

    tsc_mhz = args.tsc_mhz or detect_tsc_mhz()
    out_path = args.out or os.path.join(args.dir, "wait_summary.csv")

    conditions = discover_conditions(args.dir)
    if not conditions:
        print(f"[ERROR] No condition directories with .bin files found in {args.dir}", file=sys.stderr)
        sys.exit(1)

    conditions.sort(key=lambda x: condition_sort_key(x[0]))

    print(f"TSC: {tsc_mhz:.1f} MHz  →  {out_path}")

    fieldnames = ["condition", "n_samples", "tsc_mhz",
                  "min_us", "p10_us", "p25_us", "p50_us", "p75_us",
                  "p90_us", "p95_us", "p99_us", "p999_us", "max_us"]

    rows = []
    for name, path in conditions:
        samples = load_condition(path)
        if samples is None or len(samples) == 0:
            print(f"  [{name}] no samples, skipping")
            continue
        stats = extract_stats(samples, tsc_mhz)
        row = {"condition": name, "tsc_mhz": f"{tsc_mhz:.1f}", **{k: f"{v:.4f}" for k, v in stats.items()}}
        row["n_samples"] = str(stats["n_samples"])
        rows.append(row)
        print(f"  [{name}] n={stats['n_samples']:,}  "
              f"p50={stats['p50_us']:.3f}µs  p99={stats['p99_us']:.3f}µs  p999={stats['p999_us']:.3f}µs")

    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Saved: {out_path}")


if __name__ == "__main__":
    main()
