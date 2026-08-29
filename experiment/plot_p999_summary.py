#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_p999_summary.py \
#       [--dir experiment/results/utdelay_p999_YYYYMMDD_HHMMSS] \
#       [--out PATH]
#
# Parameters:
#   --dir DIR   p999 sweep 実験結果ディレクトリ（raw.csv が存在すること）
#   --out PATH  出力画像パス（省略で <DIR>/p999_summary.pdf）
#
# Output:
#   p999_summary.pdf — QPS（上段）・p99/p99.9 レスポンスレイテンシ（下段）の N 別比較
#
# Prerequisites:
#   pip install numpy matplotlib

import argparse
import csv
import os
import re

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

DEFAULT_DIR = "experiment/results/utdelay_p999_20260702_112351"
OPT_LABEL   = "N10"   # 最良 N（赤ハイライト）


def load_csv(path):
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


def sort_key(label):
    if label == "master":
        return -1
    m = re.search(r"(\d+)", label)
    return int(m.group(1)) if m else 0


def aggregate(raw):
    result = {}
    for label, vals in raw.items():
        result[label] = {
            "mean_qps":  np.mean(vals["qps"]),
            "mean_p99":  np.mean(vals["p99"]),
            "mean_p999": np.mean(vals["p999"]),
        }
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    csv_path = os.path.join(args.dir, "raw.csv")
    raw  = load_csv(csv_path)
    agg  = aggregate(raw)

    labels = sorted(agg.keys(), key=sort_key)
    qps_vals  = [agg[l]["mean_qps"]  / 1e3 for l in labels]
    p99_vals  = [agg[l]["mean_p99"]        for l in labels]
    p999_vals = [agg[l]["mean_p999"]       for l in labels]

    x = np.arange(len(labels))
    opt_idx = next((i for i, l in enumerate(labels) if l == OPT_LABEL), None)

    BAR_COLOR = "#4C72B0"
    OPT_COLOR = "#DD4444"

    fig, (ax_qps, ax_lat) = plt.subplots(
        2, 1, figsize=(10, 8),
        gridspec_kw={"height_ratios": [1, 1.3]}
    )
    fig.subplots_adjust(hspace=0.45)

    # ── 上段: QPS バー ─────────────────────────────────────────
    colors = [OPT_COLOR if i == opt_idx else BAR_COLOR for i in range(len(labels))]
    bars = ax_qps.bar(x, qps_vals, color=colors, edgecolor="white", linewidth=0.5,
                      zorder=3)
    for bar, val in zip(bars, qps_vals):
        ax_qps.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + 5,
            f"{val:.0f}k",
            ha="center", va="bottom", fontsize=7.5, color="#333333"
        )
    ax_qps.set_xticks(x)
    ax_qps.set_xticklabels(labels, fontsize=9)
    ax_qps.set_ylabel("QPS (k)", fontsize=10)
    ax_qps.set_title("QPS per N  (SPIN_ROUNDS=30)", fontsize=11)
    ax_qps.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{v:.0f}k"))
    ax_qps.set_ylim(0, max(qps_vals) * 1.15)
    ax_qps.grid(axis="y", linestyle="--", alpha=0.5, zorder=0)
    if opt_idx is not None:
        ax_qps.axvline(opt_idx, color=OPT_COLOR, linewidth=1.2,
                       linestyle="--", alpha=0.4)

    # ── 下段: p99 / p99.9 ライン（左右二軸）────────────────────
    ax_p999 = ax_lat.twinx()

    ln_p99,  = ax_lat.plot(x, p99_vals,  "s-", color="#2196F3", linewidth=2,
                            markersize=6, label="p99 (left)")
    ln_p999, = ax_p999.plot(x, p999_vals, "^-", color="#F44336", linewidth=2,
                             markersize=6, label="p99.9 (right)")

    p99_margin  = (max(p99_vals)  - min(p99_vals))  * 0.08 + 1
    p999_margin = (max(p999_vals) - min(p999_vals)) * 0.06 + 1
    for xi, p99, p999 in zip(x, p99_vals, p999_vals):
        ax_lat.text(xi, p99  - p99_margin,  f"{p99:.1f}",  ha="center",
                    va="top",    fontsize=7.5, color="#2196F3")
        ax_p999.text(xi, p999 + p999_margin, f"{p999:.1f}", ha="center",
                     va="bottom", fontsize=7.5, color="#F44336")

    ax_lat.set_xticks(x)
    ax_lat.set_xticklabels(labels, fontsize=9)
    ax_lat.set_ylabel("p99 latency (µs)  [left]",   fontsize=10, color="#2196F3")
    ax_p999.set_ylabel("p99.9 latency (µs)  [right]", fontsize=10, color="#CC2222")
    ax_lat.tick_params(axis="y", labelcolor="#2196F3")
    ax_p999.tick_params(axis="y", labelcolor="#CC2222")
    ax_lat.set_title("Response latency per N  (mutilate read)", fontsize=11)

    p99_range  = max(p99_vals)  - min(p99_vals)
    p999_range = max(p999_vals) - min(p999_vals)
    ax_lat.set_ylim(min(p99_vals)   - p99_range  * 0.2,
                    max(p99_vals)   + p99_range  * 0.3)
    ax_p999.set_ylim(min(p999_vals) - p999_range * 0.15,
                     max(p999_vals) + p999_range * 0.3)

    ax_lat.grid(axis="y", linestyle="--", alpha=0.4)
    ax_lat.legend([ln_p99, ln_p999], ["p99 (left)", "p99.9 (right)"],
                  fontsize=9, loc="upper right")
    if opt_idx is not None:
        ax_lat.axvline(opt_idx, color=OPT_COLOR, linewidth=1.2,
                       linestyle="--", alpha=0.4)

    fig.suptitle(
        "Skylake ann (Xeon Silver 4114)  /  SPIN_ROUNDS=30  /  n=10",
        fontsize=11, y=0.98
    )

    out = args.out or os.path.join(args.dir, "p999_summary.pdf")
    fig.savefig(out, dpi=150, bbox_inches="tight")
    print(f"Saved: {out}")


if __name__ == "__main__":
    main()
