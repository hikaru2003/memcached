#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_p999_sweep.py
#
# Parameters:
#   RESULT_DIR: 結果ディレクトリ（raw.csv が存在すること）
#
# Output:
#   experiment/results/p999_sweep.png
#
# Prerequisites:
#   pip install matplotlib numpy
#   experiment/results/utdelay_p999_20260625_140735/raw.csv が存在すること

import os
import re
import csv
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

RESULT_DIR = "experiment/results/utdelay_p999_20260702_112351"
OUT_PATH   = "experiment/results/p999_sweep.png"

TITLE_SUFFIX = (
    "spinlock: [PAUSE×N → trylock] × SPIN_ROUNDS=30 → mutex_lock\n"
    "Skylake ann / mc=4t (cpu 0-3) / mutilate -T4 -c1 -d32 -r1 -u0.5 / n=10"
)


def parse_csv(path):
    data = {}
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            label = row["label"]
            if label not in data:
                data[label] = {"qps": [], "p99": [], "p999": []}
            try:
                data[label]["qps"].append(float(row["QPS"]))
                data[label]["p99"].append(float(row["r_p99_us"]))
                data[label]["p999"].append(float(row["r_p999_us"]))
            except (ValueError, KeyError):
                pass
    return data


def aggregate(data):
    result = {}
    for label, vals in data.items():
        if label == "master":
            n = -1
        else:
            m = re.match(r'N(\d+)', label)
            if not m:
                continue
            n = int(m.group(1))
        result[label] = {
            "n":        n,
            "mean_qps": np.mean(vals["qps"]),
            "sd_qps":   np.std(vals["qps"], ddof=1) if len(vals["qps"]) > 1 else 0,
            "mean_p99": np.mean(vals["p99"]),
            "sd_p99":   np.std(vals["p99"], ddof=1) if len(vals["p99"]) > 1 else 0,
            "mean_p999":np.mean(vals["p999"]),
            "sd_p999":  np.std(vals["p999"], ddof=1) if len(vals["p999"]) > 1 else 0,
        }
    return result


def sorted_spinlock_points(agg, key_mean, key_sd):
    points = [(v["n"], v[key_mean], v[key_sd])
              for label, v in agg.items() if label != "master"]
    points.sort()
    xs, ys, es = zip(*points)
    return list(xs), list(ys), list(es)


def main():
    csv_path = os.path.join(RESULT_DIR, "raw.csv")
    raw  = parse_csv(csv_path)
    agg  = aggregate(raw)

    master = agg.get("master")

    fig, axes = plt.subplots(3, 1, figsize=(10, 12))
    fig.suptitle(f"p99.9 sweep: QPS / p99 / p99.9 vs pause_per_round\n{TITLE_SUFFIX}",
                 fontsize=10)

    COLOR_SPIN   = "tab:blue"
    COLOR_MASTER = "tab:red"

    panels = [
        ("mean_qps",  "sd_qps",  "Mean QPS (kQPS) ±1σ",          True),
        ("mean_p99",  "sd_p99",  "Read p99 latency (µs) ±1σ",     False),
        ("mean_p999", "sd_p999", "Read p99.9 latency (µs) ±1σ",   False),
    ]

    for ax, (key_m, key_s, ylabel, is_qps) in zip(axes, panels):
        xs, ys, es = sorted_spinlock_points(agg, key_m, key_s)

        if is_qps:
            ys = [v / 1000 for v in ys]
            es = [v / 1000 for v in es]
            master_val = master[key_m] / 1000 if master else None
        else:
            master_val = master[key_m] if master else None

        ax.errorbar(xs, ys, yerr=es, label="spinlock (N)", color=COLOR_SPIN,
                    marker='o', markersize=5, linewidth=1.5,
                    capsize=4, elinewidth=1.0)

        if master_val is not None:
            master_sd = (master[key_s] / 1000 if is_qps else master[key_s])
            ax.axhline(master_val, color=COLOR_MASTER, linestyle='--',
                       linewidth=1.2, label=f"master = {master_val:.1f}")
            ax.axhspan(master_val - master_sd, master_val + master_sd,
                       color=COLOR_MASTER, alpha=0.08)

        # N=4 を強調
        if 4 in xs:
            idx = xs.index(4)
            ax.axvline(4, color="gray", linestyle=":", linewidth=1.0, alpha=0.7)
            ax.annotate(f"N=4\n{ys[idx]:.1f}",
                        xy=(4, ys[idx]), xytext=(8, ys[idx]),
                        fontsize=8, color=COLOR_SPIN,
                        arrowprops=dict(arrowstyle="->", color=COLOR_SPIN, lw=0.8))

        ax.set_xlabel("pause_per_round (N)", fontsize=11)
        ax.set_ylabel(ylabel, fontsize=11)
        ax.legend(fontsize=9)
        ax.grid(True, alpha=0.3)
        ax.set_xlim(left=-2)

    fig.tight_layout()
    fig.savefig(OUT_PATH, dpi=150)
    print(f"saved: {OUT_PATH}")


if __name__ == "__main__":
    main()
