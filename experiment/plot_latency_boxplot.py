#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_latency_boxplot.py
#
# Description:
#   各アーキテクチャのread latencyをカスタム箱ひげ図で表示する。
#   rawログを直接パースし、複数runをmedianで集約して描画。
#   box要素: 下ひげ=min, 箱下=avg(p50代替), 中央線=p90, 箱上=p95, 上ひげ=p99
#   skylake_annのみp99.9データも取得（将来の他サーバ追加に備える）。
#
# Parameters:
#   RESULTS_BASE : 結果ディレクトリのルート（デフォルト: experiment/results）
#   EXTRA_RAW_DIRS : arch名 -> rawディレクトリパス（arch別ディレクトリ外のデータ用）
#
# Output:
#   experiment/results/utdelay_arch_r_boxplot.pdf
#
# Prerequisites:
#   pip install matplotlib numpy
#   rawログが experiment/results/{arch}/utdelay_sweep_*/raw/*.log に存在すること

import os
import re
import glob
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches

RESULTS_BASE = "experiment/results"

ARCH_INFO = {
    "broadwell":     ("Broadwell (xl170, PAUSE~10cyc)",                "tab:blue"),
    "emeraldrapids": ("Emerald Rapids (c6620, PAUSE~22cyc)",           "tab:green"),
    "skylake_ann":   ("Skylake ann (Xeon Silver 4110, PAUSE~124cyc)",  "tab:pink"),
}

# arch別ディレクトリ外のデータ（rawディレクトリパスを直接指定）
EXTRA_RAW_DIRS = {
    "skylake_ann": {
        "path": "experiment/results/utdelay_p999_20260702_112351/raw",
    },
}

COMMON_TITLE_SUFFIX = (
    "spinlock: [trylock→PAUSE×N]×30→mutex_lock / mc=4t / mut -T4 -c1 -d32 -r1 -u0.5"
)


def parse_log(path, has_p999=False):
    """mutilateログのread行から統計値を返す。
    ヘッダ行 (#type ...) でカラム位置を動的に検出する。
    旧フォーマット: avg std min 5th 10th 90th 95th 99th [999th]
    新フォーマット: avg std min 5th 10th 50th 90th 95th 99th [999th]
    """
    cols = None
    with open(path) as f:
        for line in f:
            if line.startswith("#type"):
                cols = line.split()
            elif line.startswith("read"):
                parts = line.split()
                if cols is None:
                    return None
                def col(name):
                    try:
                        return float(parts[cols.index(name)])
                    except (ValueError, IndexError):
                        return None
                return {
                    "avg":  col("avg"),
                    "min":  col("min"),
                    "p50":  col("50th"),   # 新フォーマットのみ有効、旧はNone
                    "p90":  col("90th"),
                    "p95":  col("95th"),
                    "p99":  col("99th"),
                    "p999": col("999th"),
                }
    return None


def load_raw_dir(raw_dir):
    """raw/ ディレクトリ内のログを走査し label -> [stats_dict] を返す。"""
    data = {}
    for log_path in sorted(glob.glob(os.path.join(raw_dir, "run_*.log"))):
        m = re.match(r"run_([^_]+)_\d+\.log", os.path.basename(log_path))
        if not m:
            continue
        label = m.group(1)
        stats = parse_log(log_path)
        if stats:
            data.setdefault(label, []).append(stats)
    return data


def find_latest_raw_dir(arch_dir):
    """arch_dir 内で最新の utdelay_sweep_*/raw を返す。"""
    dirs = sorted(glob.glob(os.path.join(arch_dir, "utdelay_sweep_*/raw")))
    if not dirs:
        dirs = sorted(glob.glob(os.path.join(arch_dir, "*/raw")))
    return dirs[-1] if dirs else None


def load_all():
    datasets = {}

    for arch_dir in sorted(glob.glob(os.path.join(RESULTS_BASE, "*"))):
        arch = os.path.basename(arch_dir)
        if arch not in ARCH_INFO or arch in EXTRA_RAW_DIRS:
            continue
        raw_dir = find_latest_raw_dir(arch_dir)
        if not raw_dir:
            continue
        data = load_raw_dir(raw_dir)
        if data:
            datasets[arch] = data
            print(f"  loaded {arch}: {raw_dir} ({len(data)} labels)")

    for arch, cfg in EXTRA_RAW_DIRS.items():
        raw_dir = cfg["path"]
        if not os.path.exists(raw_dir):
            print(f"  [WARN] {arch}: {raw_dir} not found, skipping")
            continue
        data = load_raw_dir(raw_dir)
        if data:
            datasets[arch] = data
            print(f"  loaded {arch}: {raw_dir} ({len(data)} labels)")

    return datasets


def label_to_n(label):
    if label == "master":
        return None
    m = re.match(r"N(\d+)$", label)
    return int(m.group(1)) if m else None


def make_bxp_stat(runs):
    """複数runの統計をmedianで集約してbxp()用dictを返す。
    whislo=min, q1=p50(なければavg), med=p90, q3=p95, whishi=p99
    """
    p50_vals = [r["p50"] for r in runs if r["p50"] is not None]
    q1_vals  = p50_vals if p50_vals else [r["avg"] for r in runs]
    return {
        "whislo": float(np.median([r["min"] for r in runs])),
        "q1":     float(np.median(q1_vals)),
        "med":    float(np.median([r["p90"] for r in runs])),
        "q3":     float(np.median([r["p95"] for r in runs])),
        "whishi": float(np.median([r["p99"] for r in runs])),
        "fliers": [],
    }


def plot_boxplot(datasets, out_path):
    # 描画順序（ARCH_INFO定義順）
    archs = [a for a in ARCH_INFO if a in datasets]
    n_archs = len(archs)

    # x軸: skylake_annが持つN値のみに絞る（annがない場合は全和集合にフォールバック）
    ann_ns = sorted({
        label_to_n(lbl)
        for lbl in datasets.get("skylake_ann", {})
        if label_to_n(lbl) is not None
    })
    all_ns = ann_ns if ann_ns else sorted({
        label_to_n(lbl)
        for arch in archs
        for lbl in datasets[arch]
        if label_to_n(lbl) is not None
    })
    n_pos = len(all_ns)
    n_to_idx = {n: i for i, n in enumerate(all_ns)}

    box_width = 0.75 / n_archs
    offsets = [(i - (n_archs - 1) / 2) * box_width for i in range(n_archs)]

    fig, ax = plt.subplots(figsize=(max(16, n_pos * 1.2), 7))

    legend_patches = []
    for i, arch in enumerate(archs):
        disp, color = ARCH_INFO[arch]
        data = datasets[arch]

        bxp_stats = []
        positions = []
        for lbl, runs in data.items():
            n = label_to_n(lbl)
            if n is None or n not in n_to_idx:
                continue
            bxp_stats.append(make_bxp_stat(runs))
            positions.append(n_to_idx[n] + offsets[i])

        if not bxp_stats:
            continue

        # N昇順でソート
        paired = sorted(zip(positions, bxp_stats))
        positions = [p for p, _ in paired]
        bxp_stats = [s for _, s in paired]

        bp = ax.bxp(
            bxp_stats,
            positions=positions,
            widths=box_width * 0.88,
            patch_artist=True,
            showfliers=False,
            manage_ticks=False,
        )

        for patch in bp["boxes"]:
            patch.set_facecolor(color)
            patch.set_alpha(0.5)
            patch.set_edgecolor(color)
        for whisker in bp["whiskers"]:
            whisker.set_color(color)
            whisker.set_linewidth(1.3)
        for cap in bp["caps"]:
            cap.set_color(color)
            cap.set_linewidth(1.3)
        for median in bp["medians"]:
            median.set_color("black")
            median.set_linewidth(1.6)

        legend_patches.append(mpatches.Patch(facecolor=color, alpha=0.6, label=disp))

    ax.set_xticks(range(n_pos))
    ax.set_xticklabels([str(n) for n in all_ns], fontsize=8)
    ax.set_xlabel("pause_per_round (N)", fontsize=12)
    ax.set_ylabel("Read latency (µs)", fontsize=12)
    ax.set_title(
        "Read latency vs pause_per_round  [box: min / avg(p50) / p90 / p95 / p99]\n"
        f"{COMMON_TITLE_SUFFIX}  /  median across runs",
        fontsize=10,
    )

    # 凡例（右上）+ box構造の説明（左上）
    arch_legend = ax.legend(handles=legend_patches, fontsize=9, loc="upper right")
    ax.add_artist(arch_legend)
    box_legend_text = (
        "Box structure:\n"
        "  ┬ p99  (upper whisker)\n"
        "  █ p95  (box top)\n"
        "  ─ p90  (median line)\n"
        "  █ avg  (box bottom, p50 proxy)\n"
        "  ┴ min  (lower whisker)"
    )
    ax.text(
        0.01, 0.97, box_legend_text,
        transform=ax.transAxes,
        fontsize=8,
        verticalalignment="top",
        fontfamily="monospace",
        bbox=dict(boxstyle="round,pad=0.4", facecolor="white", alpha=0.8),
    )

    ax.grid(True, alpha=0.3, axis="y")
    ax.set_xlim(-0.6, n_pos - 0.4)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  saved: {out_path}")


if __name__ == "__main__":
    print("Loading results...")
    datasets = load_all()

    if not datasets:
        print("[ERROR] No result data found.")
        exit(1)

    print("\nGenerating plot...")
    plot_boxplot(datasets, os.path.join(RESULTS_BASE, "utdelay_arch_r_boxplot.pdf"))

    print("\nDone.")
