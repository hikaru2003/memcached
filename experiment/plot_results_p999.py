#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_results_p999.py
#   OUTPUT_DIR=experiment/results/plots/v2 python3 experiment/plot_results_p999.py
#
# Description:
#   broadwell / icelake / skylake_ann の実験結果から3種のグラフを生成する。
#   1. スループット (QPS vs N) - broadwell + icelake + skylake_ann
#   2. レイテンシ箱ひげ図 (min / p50 / p99 / p999 vs N) - broadwell + icelake + skylake_ann
#   3. ロック獲得待ち時間 (wait distribution p50/p99/p999 vs N) - 3アーキ
#   4. アーキ別全N箱ひげ図 (per-arch, all N values)
#
# Parameters (env vars):
#   OUTPUT_DIR  - グラフ出力先ディレクトリ (default: experiment/results/plots/v1)
#
# Output:
#   $OUTPUT_DIR/qps_comparison.pdf
#   $OUTPUT_DIR/latency_boxplot.pdf
#   $OUTPUT_DIR/wait_distribution.pdf
#   $OUTPUT_DIR/latency_boxplot_{arch}.pdf
#
# Prerequisites:
#   pip install matplotlib numpy
#   experiment/results/{arch}/utdelay_p999_*/raw.csv が存在すること
#   experiment/results/{arch}/wait_dist_*/wait_summary.csv が存在すること

import csv
import glob
import math
import os
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
from scipy.interpolate import PchipInterpolator

# Japanese font support
matplotlib.rcParams["font.family"] = "Noto Sans CJK JP"
matplotlib.rcParams["axes.unicode_minus"] = False

RESULTS_BASE = "experiment/results"
OUTPUT_DIR   = os.environ.get("OUTPUT_DIR", os.path.join(RESULTS_BASE, "plots", "v2"))
os.makedirs(OUTPUT_DIR, exist_ok=True)

ARCH_INFO = {
    "broadwell":     {"label": "Broadwell (xl170, PAUSE~10cy)",           "color": "tab:blue"},
    "icelake":       {"label": "Ice Lake (sm110p, PAUSE~39cy)",           "color": "tab:orange"},
    "emeraldrapids": {"label": "Emerald Rapids (c6620, PAUSE~37cy)",      "color": "tab:red"},
    "skylake_ann":   {"label": "Skylake ann (Silver 4110, PAUSE~124cy)",  "color": "tab:green"},
}

# skylake_ann の utdelay / wait は arch サブディレクトリ外（ann サーバで直接実行した結果）
# emeraldrapids は utdelay_p999_* に N=0/4/30 しかないため、より詳細な utdelay_sweep_* を使う
UTDELAY_PATH_OVERRIDE = {
    "skylake_ann":   "experiment/results/archive/20260910/misc/utdelay_p999_20260708_233528/raw.csv",
    "emeraldrapids": "experiment/results/archive/20260910/emeraldrapids/utdelay_sweep_20260624_015236/raw.csv",
}
WAIT_PATH_OVERRIDE = {
    "skylake_ann": "experiment/results/wait_dist_20260709_225409/wait_summary.csv",
}


# -------------------------------------------------------------------
# Data loading
# -------------------------------------------------------------------

def find_utdelay_csv(arch):
    if arch in UTDELAY_PATH_OVERRIDE:
        p = UTDELAY_PATH_OVERRIDE[arch]
        return p if os.path.exists(p) else None
    pattern = os.path.join(RESULTS_BASE, arch, "utdelay_p999_*", "raw.csv")
    candidates = glob.glob(pattern)
    if not candidates:
        return None
    return max(candidates, key=os.path.getsize)


def find_wait_csv(arch):
    if arch in WAIT_PATH_OVERRIDE:
        p = WAIT_PATH_OVERRIDE[arch]
        return p if os.path.exists(p) else None
    pattern = os.path.join(RESULTS_BASE, arch, "wait_dist_*", "wait_summary.csv")
    candidates = sorted(glob.glob(pattern))
    return candidates[-1] if candidates else None


def parse_utdelay(path):
    """raw.csv → {n_or_master: {"qps":[], "r_p50":[], "r_p99":[], "r_p999":[]}}"""
    data = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            label = row["label"]
            key = "master" if label == "master" else int(row["pause_per_round"])
            bucket = data.setdefault(key, {"qps": [], "r_p50": [], "r_p99": [], "r_p999": []})
            try:
                bucket["qps"].append(float(row["QPS"]))
                bucket["r_p50"].append(float(row["r_p50_us"]))
                bucket["r_p99"].append(float(row["r_p99_us"]))
                bucket["r_p999"].append(float(row["r_p999_us"]))
            except (ValueError, KeyError):
                pass
    return data


def parse_min_from_logs(raw_dir):
    """raw/run_N{n}_*.log と run_master_*.log の read 行 col4 (min latency) を読む"""
    data = {}
    if not os.path.isdir(raw_dir):
        return data
    for logfile in glob.glob(os.path.join(raw_dir, "run_*.log")):
        basename = os.path.basename(logfile)
        m_n = re.match(r"run_N(\d+)_\d+\.log$", basename)
        m_master = re.match(r"run_master_\d+\.log$", basename)
        if m_n:
            key = int(m_n.group(1))
        elif m_master:
            key = "master"
        else:
            continue
        with open(logfile) as f:
            for line in f:
                if line.startswith("read"):
                    cols = line.split()
                    try:
                        data.setdefault(key, []).append(float(cols[3]))
                    except (IndexError, ValueError):
                        pass
                    break
    return data


def parse_wait(path):
    """{n: {"p50":, "p99":, "p999":}}, tsc_mhz"""
    data = {}
    tsc_mhz = None
    with open(path) as f:
        for row in csv.DictReader(f):
            if tsc_mhz is None:
                try:
                    tsc_mhz = float(row["tsc_mhz"])
                except (ValueError, KeyError):
                    pass
            m = re.match(r"N(\d+)$", row["condition"])
            if not m:
                continue
            n = int(m.group(1))
            try:
                data[n] = {
                    "p50":  float(row["p50_us"]),
                    "p99":  float(row["p99_us"]),
                    "p999": float(row["p999_us"]),
                }
            except (ValueError, KeyError):
                pass
    return data, tsc_mhz


def _mean(vs):
    return sum(vs) / len(vs) if vs else float("nan")


def _std(vs):
    if len(vs) < 2:
        return 0.0
    m = _mean(vs)
    return math.sqrt(sum((v - m) ** 2 for v in vs) / (len(vs) - 1))


def _cv(vs):
    """CV% = std / mean * 100"""
    m = _mean(vs)
    if math.isnan(m) or m == 0:
        return 0.0
    return _std(vs) / m * 100


# -------------------------------------------------------------------
# Load
# -------------------------------------------------------------------
utdelay = {}
utdelay_min = {}
for arch in ARCH_INFO:
    p = find_utdelay_csv(arch)
    if p:
        utdelay[arch] = parse_utdelay(p)
        raw_dir = os.path.join(os.path.dirname(p), "raw")
        utdelay_min[arch] = parse_min_from_logs(raw_dir)
        print(f"  utdelay [{arch}] <- {p}  ({sum(len(v['qps']) for v in utdelay[arch].values())} rows)")
    else:
        print(f"  utdelay [{arch}] NOT FOUND")

# QPS peak N per arch (used in both qps_comparison and wait_distribution)
peak_qps_n = {
    arch: max(
        (n for n in d if n != "master"),
        key=lambda n: _mean(d[n]["qps"])
    )
    for arch, d in utdelay.items()
}

wait = {}
wait_tsc = {}
for arch in ARCH_INFO:
    p = find_wait_csv(arch)
    if p:
        wait[arch], wait_tsc[arch] = parse_wait(p)
        print(f"  wait    [{arch}] <- {p}")
    else:
        print(f"  wait    [{arch}] NOT FOUND")


# -------------------------------------------------------------------
# Plot 1: Throughput (QPS vs N)
# -------------------------------------------------------------------
QPS_LABEL_JA = {
    "broadwell":     "Broadwell",
    "icelake":       "Sunny Cove",
    "emeraldrapids": "Emerald Rapids",
    "skylake_ann":   "Skylake",
}

fig, ax = plt.subplots(figsize=(14, 7))

for arch, info in ARCH_INFO.items():
    d = utdelay.get(arch)
    if not d:
        continue
    ns       = sorted(k for k in d if k != "master")
    means    = [_mean(d[n]["qps"]) / 1e3 for n in ns]
    cvs      = [_cv(d[n]["qps"]) / 100 * _mean(d[n]["qps"]) / 1e3 for n in ns]
    ns_arr   = np.array(ns, dtype=float)
    mean_arr = np.array(means)

    # spline curve between measured N values
    spline   = PchipInterpolator(ns_arr, mean_arr)
    xs_fine  = np.linspace(ns_arr[0], ns_arr[-1], 500)
    ys_fine  = spline(xs_fine)
    ax.plot(xs_fine, ys_fine, color=info["color"], linewidth=4.0,
            label=QPS_LABEL_JA.get(arch, info["label"]))

    # measured points + CV% error bars
    ax.scatter(ns_arr, mean_arr, color=info["color"], s=40, zorder=5)
    ax.errorbar(ns, means, yerr=cvs, fmt="none",
                color=info["color"], capsize=3, elinewidth=1.0, alpha=0.6)

ax.set_xlabel("PAUSE 実行回数/スピン", fontsize=20)
ax.set_ylabel("スループット [Kqps]", fontsize=20)
ax.tick_params(axis="both", labelsize=20)

from matplotlib.lines import Line2D as _Line2D_q
ax.grid(True, alpha=0.3)
ax.set_xlim(-3, 205)
ax.legend(fontsize=16, loc="best", framealpha=0.9)

out1 = os.path.join(OUTPUT_DIR, "qps_comparison.pdf")
fig.savefig(out1, bbox_inches="tight")
plt.close(fig)
print(f"Saved: {out1}")


# -------------------------------------------------------------------
# Plot 1c: QPS spline chart (スプライン補間で測定点間を滑らかに接続)
#   Measured points shown as markers + CV% error bars;
#   gaps between N values filled with cubic spline interpolation.
# -------------------------------------------------------------------
fig, ax = plt.subplots(figsize=(12, 6))

for arch, info in ARCH_INFO.items():
    d = utdelay.get(arch)
    if not d:
        continue
    ns    = sorted(k for k in d if k != "master")
    means = [_mean(d[n]["qps"]) / 1e3 for n in ns]
    cvs   = [_cv(d[n]["qps"]) / 100 * _mean(d[n]["qps"]) / 1e3 for n in ns]

    ns_arr    = np.array(ns, dtype=float)
    means_arr = np.array(means)
    spline    = PchipInterpolator(ns_arr, means_arr)
    xs_fine   = np.linspace(ns_arr[0], ns_arr[-1], 500)
    ys_fine   = spline(xs_fine)

    ax.plot(xs_fine, ys_fine, color=info["color"], linewidth=1.5, label=info["label"])
    ax.scatter(ns_arr, means_arr, color=info["color"], s=18, zorder=5)
    ax.errorbar(ns, means, yerr=cvs, fmt="none",
                color=info["color"], capsize=2, elinewidth=0.8, alpha=0.6)

    if "master" in d:
        base = _mean(d["master"]["qps"]) / 1e3
        ax.axhline(base, color=info["color"], linestyle="--",
                   linewidth=1.8, alpha=0.85)

    pn = peak_qps_n.get(arch)
    if pn is not None:
        ax.axvline(pn, color=info["color"], linestyle="--", linewidth=1.2, alpha=0.7)
        ax.annotate(f"N={pn}",
                    xy=(pn, 0), xycoords=("data", "axes fraction"),
                    xytext=(0, -22), textcoords="offset points",
                    ha="center", va="top", fontsize=8,
                    color=info["color"], fontweight="bold")

ax.set_xlabel("N  (PAUSE instructions per round)", fontsize=12)
ax.set_ylabel("QPS  (K ops/s)", fontsize=12)
ax.set_title("Throughput vs PAUSE count  [cubic spline, error bar = CV%]\n"
             "spinlock: [trylock → PAUSE×N] × 30 → mutex_lock  /  mc=4t  mut -T4 -c1 -d32",
             fontsize=11)
ax.legend(fontsize=9, loc="center right",
          bbox_to_anchor=(0.99, 0.38), framealpha=0.9)
ax.grid(True, alpha=0.3)
ax.set_xlim(-3, 205)

out1c = os.path.join(OUTPUT_DIR, "qps_step.pdf")
fig.savefig(out1c, bbox_inches="tight")
plt.close(fig)
print(f"Saved: {out1c}")


# -------------------------------------------------------------------
# Plot 1b: Normalized Throughput bar chart (QPS / master QPS vs N)
#   One subplot per arch, stacked vertically
# -------------------------------------------------------------------
archs_with_master = [a for a in ARCH_INFO if a in utdelay and "master" in utdelay[a]]

fig, axes = plt.subplots(len(archs_with_master), 1,
                         figsize=(18, 4.5 * len(archs_with_master)),
                         constrained_layout=True)
if len(archs_with_master) == 1:
    axes = [axes]

for ax_idx, arch in enumerate(archs_with_master):
    info     = ARCH_INFO[arch]
    d        = utdelay[arch]
    base_qps = _mean(d["master"]["qps"])
    ns       = sorted(k for k in d if k != "master")
    means    = [_mean(d[n]["qps"]) / base_qps for n in ns]
    cvs      = [_cv(d[n]["qps"]) / 100 * _mean(d[n]["qps"]) / base_qps for n in ns]
    p50_vals = [_mean(d[n]["r_p50"]) for n in ns]

    ax_l = axes[ax_idx]
    ax_r = ax_l.twinx()
    xs = range(len(ns))

    ax_l.bar(xs, means, yerr=cvs, capsize=2,
             color=info["color"], alpha=0.55,
             error_kw={"elinewidth": 0.8}, label="Normalized QPS (left)")
    ax_l.axhline(1.0, color="grey", linestyle="--", linewidth=1.0, alpha=0.7, label="master (=1.0)")

    l_p50, = ax_r.plot(list(xs), p50_vals, color="tab:red", marker="o",
                       markersize=3, linewidth=1.5, label="p50 latency (right)")

    pn = peak_qps_n.get(arch)
    if pn is not None and pn in ns:
        pi = ns.index(pn)
        ax_l.axvline(pi, color=info["color"], linestyle="--", linewidth=1.2, alpha=0.7)
        ax_l.annotate(f"N={pn}",
                      xy=(pi, 0), xycoords=("data", "axes fraction"),
                      xytext=(0, -22), textcoords="offset points",
                      ha="center", va="top", fontsize=8,
                      color=info["color"], fontweight="bold")

    ax_l.set_xticks(list(xs))
    ax_l.set_xticklabels([str(n) for n in ns], fontsize=8, rotation=45, ha="right")
    ax_l.set_xlabel("N  (PAUSE instructions per round)", fontsize=10)
    ax_l.set_ylabel("Normalized QPS", fontsize=10)
    ax_r.set_ylabel("p50 latency (μs)  [right]", color="tab:red", fontsize=10)
    ax_r.tick_params(axis="y", labelcolor="tab:red")
    ax_l.set_title(info["label"], fontsize=11)
    ax_l.grid(True, axis="y", alpha=0.3)

    handles_l, labels_l = ax_l.get_legend_handles_labels()
    ax_l.legend(handles_l + [l_p50], labels_l + [l_p50.get_label()],
                fontsize=8, loc="upper right")

fig.suptitle("Normalized Throughput vs PAUSE count  (QPS / master QPS, error bar = CV%)\n"
             "spinlock: [trylock → PAUSE×N] × 30 → mutex_lock  /  mc=4t  mut -T4 -c1 -d32",
             fontsize=12)

out1b = os.path.join(OUTPUT_DIR, "qps_normalized.pdf")
fig.savefig(out1b, bbox_inches="tight")
plt.close(fig)
print(f"Saved: {out1b}")


# -------------------------------------------------------------------
# Plot 2: Latency boxplot
#   Box structure (each box = median across runs of each percentile):
#     upper whisker : p999
#     box top       : p99
#     box bottom    : p50
#     lower whisker : avg
# -------------------------------------------------------------------
archs_with_utdelay = [a for a in ARCH_INFO if a in utdelay]
BOX_NS = sorted({n for a in archs_with_utdelay for n in utdelay[a] if n != "master" and n <= 100})

n_archs   = len(archs_with_utdelay)
box_width = 0.6
group_gap = 0.8
YBREAK    = 220   # axis break point
YTOP      = 300   # top of upper panel; values above annotated with ↑
YMAX_ANNOT = YTOP

def _median(vs):
    if not vs:
        return float("nan")
    s = sorted(vs)
    m = len(s) // 2
    return s[m] if len(s) % 2 else (s[m-1] + s[m]) / 2

# --- broken axis setup ---
# figsize=(36,14), height_ratios=[1,5]:
#   top (220-308, 88μs): ~14*150*(1/6) ≈ 350px → 4.0 px/μs
#   bot (0-223, 223μs):  ~14*150*(5/6) ≈ 1750px → 7.8 px/μs  (下パネルを約2倍密に)
import matplotlib.gridspec as gridspec
fig = plt.figure(figsize=(36, 14))
gs  = gridspec.GridSpec(2, 1, height_ratios=[1, 5], hspace=0.04)
ax_top = fig.add_subplot(gs[0])                   # 220-300 (compressed)
ax_bot = fig.add_subplot(gs[1], sharex=ax_top)    # 0-220   (expanded)

# hide inner spines and ticks at break
ax_top.spines["bottom"].set_visible(False)
ax_bot.spines["top"].set_visible(False)
ax_top.tick_params(bottom=False, labelbottom=False)

xtick_pos, xtick_lbl = [], []
_annotated = set()   # prevent duplicate ↑ annotations

for i, n in enumerate(BOX_NS):
    base_x = i * (n_archs + group_gap)
    center  = base_x + (n_archs - 1) / 2
    xtick_pos.append(center)
    xtick_lbl.append(f"N={n}")

    for j, arch in enumerate(archs_with_utdelay):
        dd = utdelay[arch].get(n, {})
        min_med  = _median([v for v in utdelay_min[arch].get(n, []) if not math.isnan(v)])
        p50_med  = _median([v for v in dd.get("r_p50",  []) if not math.isnan(v)])
        p99_med  = _median([v for v in dd.get("r_p99",  []) if not math.isnan(v)])
        p999_med = _median([v for v in dd.get("r_p999", []) if not math.isnan(v)])

        x     = base_x + j
        color = ARCH_INFO[arch]["color"]

        if math.isnan(p50_med) or math.isnan(p99_med):
            continue

        # draw on BOTH axes — ylim applied after loop clips each panel
        for ax_ in (ax_top, ax_bot):
            ax_.add_patch(plt.Rectangle(
                (x - box_width/2, p50_med),
                box_width, p99_med - p50_med,
                facecolor=color, alpha=0.65, edgecolor="black", linewidth=0.8,
                clip_on=True
            ))
            if not math.isnan(min_med):
                ax_.vlines(x, min_med, p50_med, color="black", linewidth=1.2)
                ax_.hlines(min_med, x - box_width*0.4, x + box_width*0.4,
                           color="black", linewidth=1.2)
            if not math.isnan(p999_med):
                whisker_top = min(p999_med, YTOP)
                ax_.vlines(x, p99_med, whisker_top, color="black", linewidth=1.2)
                if p999_med <= YTOP:
                    ax_.hlines(p999_med, x - box_width*0.4, x + box_width*0.4,
                               color="black", linewidth=1.2)

        if not math.isnan(p999_med) and p999_med > YTOP and (x, arch) not in _annotated:
            ax_top.annotate(f"↑{p999_med:.0f}",
                            xy=(x, YTOP), fontsize=9.0,
                            ha="center", va="bottom",
                            color="black", fontweight="bold")
            _annotated.add((x, arch))

# lock ylim AFTER all patches are drawn (prevents autoscale override)
ax_top.set_ylim(YBREAK, YTOP + 8)
ax_bot.set_ylim(0, YBREAK + 3)
ax_top.autoscale(False)
ax_bot.autoscale(False)

# y-axis ticks: bottom = fine (every 20μs), top = only 220 and 300
ax_bot.set_yticks(list(range(0, YBREAK + 1, 20)))
ax_top.set_yticks([YBREAK, YTOP])

# diagonal break marks (drawn after ylim is locked)
bkw = dict(color="k", clip_on=False, linewidth=1.0)
dk = 0.012
for _ax, ypos in [(ax_top, 0), (ax_bot, 1)]:
    tr = _ax.transAxes
    _ax.plot((-dk, +dk), (ypos - dk, ypos + dk), transform=tr, **bkw)
    _ax.plot((1-dk, 1+dk), (ypos - dk, ypos + dk), transform=tr, **bkw)

ax_bot.set_xticks(xtick_pos)
ax_bot.set_xticklabels(xtick_lbl, fontsize=11, rotation=45, ha="right")
ax_bot.set_xlabel("N  (PAUSE instructions per round)", fontsize=14)
ax_bot.set_ylabel("Read Latency (μs)", fontsize=14)
ax_bot.tick_params(axis="y", labelsize=12)
ax_top.tick_params(axis="y", labelsize=12)

peak_note = "  /  ★ = QPS peak N per arch: " + \
    ", ".join(f"{ARCH_INFO[a]['label'].split()[0]} N={peak_qps_n[a]}"
              for a in archs_with_utdelay if a in peak_qps_n)
ax_top.set_title(
    "Read Latency vs PAUSE count  [box: min / p50 / p99 / p999]\n"
    "spinlock: [trylock→PAUSE×N]×30→mutex_lock  /  mc=4t  mut -T4 -c1 -d32  /  median across runs"
    f"  /  y > {YTOP} μs annotated as ↑" + peak_note,
    fontsize=12
)
ax_top.grid(True, axis="y", alpha=0.3)
ax_bot.grid(True, axis="y", alpha=0.3)

from matplotlib.lines import Line2D
struct_lines = [
    Line2D([0],[0], color="black", linewidth=1.2, label="p999  (upper whisker)"),
    mpatches.Patch(facecolor="grey", alpha=0.65, edgecolor="black", label="p99   (box top)"),
    mpatches.Patch(facecolor="grey", alpha=0.65, edgecolor="black", label="p50   (box bottom)"),
    Line2D([0],[0], color="black", linewidth=1.2, label="min   (lower whisker)"),
]
arch_handles = [
    mpatches.Patch(facecolor=ARCH_INFO[a]["color"], alpha=0.65, label=ARCH_INFO[a]["label"])
    for a in archs_with_utdelay
]
fig.legend(handles=struct_lines + arch_handles, fontsize=12,
           loc="lower center", bbox_to_anchor=(0.5, 0.0),
           ncol=4, framealpha=0.9, borderaxespad=0.2)

fig.subplots_adjust(left=0.06, right=0.99, top=0.95, bottom=0.10)
out2 = os.path.join(OUTPUT_DIR, "latency_boxplot.pdf")
fig.savefig(out2, dpi=150)
plt.close(fig)
print(f"Saved: {out2}")


# -------------------------------------------------------------------
# Plot 2b/2c: Normalized Latency boxplot
#   2b: normalized to master (no-spinlock baseline)
#   2c: normalized to N=0 (with-spinlock, no-PAUSE baseline)
# -------------------------------------------------------------------
from matplotlib.lines import Line2D as _Line2D2

def _draw_normalized_boxplot(baseline_key, out_path, baseline_label):
    fig, ax = plt.subplots(figsize=(36, 6))
    xtick_pos_, xtick_lbl_ = [], []

    for i, n in enumerate(BOX_NS):
        bx = i * (n_archs + group_gap)
        cx = bx + (n_archs - 1) / 2
        xtick_pos_.append(cx)
        xtick_lbl_.append(f"N={n}")

        for j, arch in enumerate(archs_with_utdelay):
            d      = utdelay[arch]
            d_base = d.get(baseline_key, {})
            dn     = d.get(n, {})
            color  = ARCH_INFO[arch]["color"]

            min0   = _median([v for v in utdelay_min[arch].get(baseline_key, []) if not math.isnan(v)])
            p50_0  = _median([v for v in d_base.get("r_p50",  []) if not math.isnan(v)])
            p99_0  = _median([v for v in d_base.get("r_p99",  []) if not math.isnan(v)])
            p999_0 = _median([v for v in d_base.get("r_p999", []) if not math.isnan(v)])

            min_n  = _median([v for v in utdelay_min[arch].get(n, []) if not math.isnan(v)])
            p50_n  = _median([v for v in dn.get("r_p50",  []) if not math.isnan(v)])
            p99_n  = _median([v for v in dn.get("r_p99",  []) if not math.isnan(v)])
            p999_n = _median([v for v in dn.get("r_p999", []) if not math.isnan(v)])

            if any(math.isnan(v) or v == 0 for v in [p50_0, p99_0]):
                continue
            if math.isnan(p50_n) or math.isnan(p99_n):
                continue

            norm_p50  = p50_n  / p50_0
            norm_p99  = p99_n  / p99_0
            norm_p999 = p999_n / p999_0 if (not math.isnan(p999_n) and p999_0 > 0) else float("nan")
            norm_min  = min_n  / min0   if (not math.isnan(min_n) and not math.isnan(min0) and min0 > 0) else float("nan")

            x = bx + j
            ax.add_patch(plt.Rectangle(
                (x - box_width/2, norm_p50),
                box_width, norm_p99 - norm_p50,
                facecolor=color, alpha=0.65, edgecolor="black", linewidth=0.8
            ))
            if not math.isnan(norm_min):
                ax.vlines(x, norm_min, norm_p50, color="black", linewidth=1.2)
                ax.hlines(norm_min, x - box_width*0.4, x + box_width*0.4, color="black", linewidth=1.2)
            if not math.isnan(norm_p999):
                ax.vlines(x, norm_p99, norm_p999, color="black", linewidth=1.2)
                ax.hlines(norm_p999, x - box_width*0.4, x + box_width*0.4, color="black", linewidth=1.2)

    ax.axhline(1.0, color="grey", linestyle="--", linewidth=1.0, alpha=0.7,
               label=f"{baseline_label} (=1.0)")
    ax.set_xticks(xtick_pos_)
    ax.set_xticklabels(xtick_lbl_, fontsize=7, rotation=45, ha="right")
    ax.set_ylabel(f"Normalized Latency  (relative to {baseline_label})", fontsize=12)
    ax.set_xlabel("N  (PAUSE instructions per round)", fontsize=12)
    ax.set_title(
        f"Normalized Read Latency vs PAUSE count  [normalized to {baseline_label}]\n"
        "spinlock: [trylock→PAUSE×N]×30→mutex_lock  /  mc=4t  mut -T4 -c1 -d32  /  median across runs"
        + peak_note,
        fontsize=9
    )
    ax.grid(True, axis="y", alpha=0.3)
    struct_lines_ = [
        _Line2D2([0],[0], color="black", linewidth=1.2, label="p999  (upper whisker)"),
        mpatches.Patch(facecolor="grey", alpha=0.65, edgecolor="black", label="p99   (box top)"),
        mpatches.Patch(facecolor="grey", alpha=0.65, edgecolor="black", label="p50   (box bottom)"),
        _Line2D2([0],[0], color="black", linewidth=1.2, label="min   (lower whisker)"),
    ]
    arch_handles_ = [
        mpatches.Patch(facecolor=ARCH_INFO[a]["color"], alpha=0.65, label=ARCH_INFO[a]["label"])
        for a in archs_with_utdelay
    ]
    ax.legend(handles=struct_lines_ + arch_handles_, fontsize=8,
              loc="upper right", ncol=2, framealpha=0.9)
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: {out_path}")

out2b = os.path.join(OUTPUT_DIR, "latency_boxplot_normalized_master.pdf")
_draw_normalized_boxplot("master", out2b, "master")

out2c = os.path.join(OUTPUT_DIR, "latency_boxplot_normalized_n0.pdf")
_draw_normalized_boxplot(0, out2c, "N=0")


# -------------------------------------------------------------------
# Plot 3: Wait distribution — 3 rows (one per arch), dual y-axis
#   Left  axis : median (p50) — blue
#   Right axis : p99 (orange) + p999 (red)
#   Labels shown at key N values only to avoid clutter
# -------------------------------------------------------------------
WAIT_LABEL_NS = {0, 4, 10, 15, 30, 45, 100, 150, 200}

archs_with_wait = [a for a in ARCH_INFO if a in wait]
fig, axes = plt.subplots(len(archs_with_wait), 1,
                         figsize=(14, 5 * len(archs_with_wait)),
                         constrained_layout=True)
if len(archs_with_wait) == 1:
    axes = [axes]

for ax_idx, arch in enumerate(archs_with_wait):
    info = ARCH_INFO[arch]
    d    = wait[arch]
    tsc  = wait_tsc.get(arch)
    ns        = sorted(d)
    p50_vals  = [d[n]["p50"]  for n in ns]
    p99_vals  = [d[n]["p99"]  for n in ns]
    p999_vals = [d[n]["p999"] for n in ns]

    ax_l = axes[ax_idx]
    ax_r = ax_l.twinx()

    ns_arr   = np.array(ns, dtype=float)
    xs_fine  = np.linspace(ns_arr[0], ns_arr[-1], 500)

    l1, = ax_l.plot(xs_fine, PchipInterpolator(ns_arr, p50_vals)(xs_fine),
                    color="tab:blue",   linewidth=1.5, label="median (left)")
    ax_l.scatter(ns_arr, p50_vals,  color="tab:blue",   s=16, zorder=5, marker="o")

    l2, = ax_r.plot(xs_fine, PchipInterpolator(ns_arr, p99_vals)(xs_fine),
                    color="tab:orange", linewidth=1.5, label="p99 (right)")
    ax_r.scatter(ns_arr, p99_vals,  color="tab:orange", s=16, zorder=5, marker="s")

    l3, = ax_r.plot(xs_fine, PchipInterpolator(ns_arr, p999_vals)(xs_fine),
                    color="tab:red",    linewidth=1.5, label="p999 (right)")
    ax_r.scatter(ns_arr, p999_vals, color="tab:red",    s=16, zorder=5, marker="^")

    # peak QPS N — vertical dashed line + x-axis label (aligned to QPS graph)
    peak_n = peak_qps_n.get(arch)
    l4 = ax_l.axvline(peak_n, color="tab:blue", linestyle="--", linewidth=1.2,
                      alpha=0.7, label=f"peak N={peak_n}")
    ax_l.annotate(f"N={peak_n}",
                  xy=(peak_n, 0), xycoords=("data", "axes fraction"),
                  xytext=(0, -22), textcoords="offset points",
                  ha="center", va="top", fontsize=8,
                  color="tab:blue", fontweight="bold")

    for n, p50, p99, p999 in zip(ns, p50_vals, p99_vals, p999_vals):
        if n not in WAIT_LABEL_NS:
            continue
        ax_l.annotate(f"{p50:.2f}", (n, p50),  fontsize=6.5, color="tab:blue",
                      textcoords="offset points", xytext=(0, 5), ha="center")
        ax_r.annotate(f"{p99:.1f}",  (n, p99),  fontsize=6.5, color="tab:orange",
                      textcoords="offset points", xytext=(0, 5), ha="center")
        ax_r.annotate(f"{p999:.1f}", (n, p999), fontsize=6.5, color="tab:red",
                      textcoords="offset points", xytext=(0, 5), ha="center")

    tsc_str = f" / TSC {tsc:.0f} MHz" if tsc else ""
    ax_l.set_title(f"{info['label']}{tsc_str}", fontsize=11)
    ax_l.set_xlabel("N  (PAUSE instructions per round)", fontsize=10)
    ax_l.set_ylabel("median wait (μs)  [left]",      color="tab:blue",   fontsize=10)
    ax_r.set_ylabel("p99 / p999 wait (μs)  [right]", color="tab:red",    fontsize=10)
    ax_l.tick_params(axis="y", labelcolor="tab:blue")
    ax_r.tick_params(axis="y", labelcolor="tab:red")
    ax_l.grid(True, alpha=0.3)
    ax_l.legend([l1, l2, l3, l4], [l.get_label() for l in [l1, l2, l3, l4]],
                fontsize=8, loc="upper right")

fig.suptitle("Lock Acquisition Wait Time vs N\n"
             "spinlock: [trylock→PAUSE×N]×30 → mutex_lock", fontsize=12)

out3 = os.path.join(OUTPUT_DIR, "wait_distribution.pdf")
fig.savefig(out3, bbox_inches="tight")
plt.close(fig)
print(f"Saved: {out3}")

# -------------------------------------------------------------------
# Plot 4: Per-arch latency boxplot (all N values)
#   One figure per arch, x-axis = all N values
#   Box: min (lower whisker) / p50 (box bottom) / p99 (box top) / p999 (upper whisker)
# -------------------------------------------------------------------
from matplotlib.lines import Line2D as _Line2D

out4_paths = []

for arch in archs_with_utdelay:
    info  = ARCH_INFO[arch]
    d_all = utdelay[arch]
    d_min = utdelay_min[arch]
    ns    = sorted(k for k in d_all if k != "master")

    fig, ax = plt.subplots(figsize=(20, 6))
    color = info["color"]

    for i, n in enumerate(ns):
        d       = d_all[n]
        min_med  = _median([v for v in d_min.get(n, [])     if not math.isnan(v)])
        p50_med  = _median([v for v in d.get("r_p50",  [])  if not math.isnan(v)])
        p99_med  = _median([v for v in d.get("r_p99",  [])  if not math.isnan(v)])
        p999_med = _median([v for v in d.get("r_p999", [])  if not math.isnan(v)])

        if math.isnan(p50_med) or math.isnan(p99_med):
            continue

        bw = 0.6
        # box: p50 → p99
        ax.add_patch(plt.Rectangle(
            (i - bw/2, p50_med), bw, p99_med - p50_med,
            facecolor=color, alpha=0.65, edgecolor="black", linewidth=0.8
        ))
        # lower whisker: min → p50
        if not math.isnan(min_med):
            ax.vlines(i, min_med, p50_med, color="black", linewidth=1.0)
            ax.hlines(min_med, i - bw*0.4, i + bw*0.4, color="black", linewidth=1.0)
        # upper whisker: p99 → p999
        if not math.isnan(p999_med):
            ax.vlines(i, p99_med, p999_med, color="black", linewidth=1.0)
            ax.hlines(p999_med, i - bw*0.4, i + bw*0.4, color="black", linewidth=1.0)

    ax.set_xticks(range(len(ns)))
    ax.set_xticklabels([f"N={n}" for n in ns], fontsize=8, rotation=45, ha="right")
    ax.set_ylabel("Read Latency (μs)", fontsize=12)
    ax.set_xlabel("N  (PAUSE instructions per round)", fontsize=12)
    ax.set_title(
        f"{info['label']}\n"
        "Read Latency [box: min / p50 / p99 / p999]  /  "
        "spinlock: [trylock→PAUSE×N]×30  /  median across runs",
        fontsize=10
    )
    ax.grid(True, axis="y", alpha=0.3)
    ax.autoscale_view()

    legend_elems = [
        _Line2D([0],[0], color="black", linewidth=1.0, label="p999  (upper whisker)"),
        mpatches.Patch(facecolor=color, alpha=0.65, edgecolor="black", label="p99   (box top)"),
        mpatches.Patch(facecolor=color, alpha=0.65, edgecolor="black", label="p50   (box bottom)"),
        _Line2D([0],[0], color="black", linewidth=1.0, label="min   (lower whisker)"),
    ]
    ax.legend(handles=legend_elems, fontsize=9, loc="upper left", framealpha=0.9)

    out = os.path.join(OUTPUT_DIR, f"latency_boxplot_{arch}.pdf")
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    out4_paths.append(out)
    print(f"Saved: {out}")


# -------------------------------------------------------------------
# Plot 5: スライド用レイテンシ箱ひげ図
#   - 横軸: 等間隔配置（グループごとに同幅）
#   - 箱・ひげの線色: 各アーキテクチャの固有色
#   - 凡例: グラフ右側に縦配置
# -------------------------------------------------------------------
fig_s = plt.figure(figsize=(38, 14))
gs_s  = gridspec.GridSpec(2, 1, height_ratios=[1, 5], hspace=0.04)
ax_s_top = fig_s.add_subplot(gs_s[0])
ax_s_bot = fig_s.add_subplot(gs_s[1], sharex=ax_s_top)

ax_s_top.spines["bottom"].set_visible(False)
ax_s_bot.spines["top"].set_visible(False)
ax_s_top.tick_params(bottom=False, labelbottom=False)

xtick_pos_s, xtick_lbl_s = [], []
_annotated_s = set()

for i, n in enumerate(BOX_NS):
    base_x_s = i * (n_archs + group_gap)
    center_s  = base_x_s + (n_archs - 1) / 2
    xtick_pos_s.append(center_s)
    xtick_lbl_s.append(str(n))

    for j, arch in enumerate(archs_with_utdelay):
        dd = utdelay[arch].get(n, {})
        min_med  = _median([v for v in utdelay_min[arch].get(n, []) if not math.isnan(v)])
        p50_med  = _median([v for v in dd.get("r_p50",  []) if not math.isnan(v)])
        p99_med  = _median([v for v in dd.get("r_p99",  []) if not math.isnan(v)])
        p999_med = _median([v for v in dd.get("r_p999", []) if not math.isnan(v)])

        x_s   = base_x_s + j
        color = ARCH_INFO[arch]["color"]

        if math.isnan(p50_med) or math.isnan(p99_med):
            continue

        for ax_ in (ax_s_top, ax_s_bot):
            ax_.add_patch(plt.Rectangle(
                (x_s - box_width/2, p50_med),
                box_width, p99_med - p50_med,
                facecolor=color, alpha=0.55, edgecolor=color, linewidth=1.2,
                clip_on=True
            ))
            if not math.isnan(min_med):
                ax_.vlines(x_s, min_med, p50_med, color=color, linewidth=1.5)
                ax_.hlines(min_med, x_s - box_width*0.4, x_s + box_width*0.4,
                           color=color, linewidth=1.5)
            if not math.isnan(p999_med):
                whisker_top_s = min(p999_med, YTOP)
                ax_.vlines(x_s, p99_med, whisker_top_s, color=color, linewidth=1.5)
                if p999_med <= YTOP:
                    ax_.hlines(p999_med, x_s - box_width*0.4, x_s + box_width*0.4,
                               color=color, linewidth=1.5)

        if not math.isnan(p999_med) and p999_med > YTOP and (n, arch) not in _annotated_s:
            ax_s_top.annotate(f"↑{p999_med:.0f}",
                              xy=(x_s, YTOP), fontsize=16,
                              ha="center", va="bottom",
                              color=color, fontweight="bold")
            _annotated_s.add((n, arch))

# ylim 固定（パッチ描画後）
ax_s_top.set_ylim(YBREAK, YTOP + 25)   # 上に余裕を持たせてアノテーションが隠れない
ax_s_bot.set_ylim(40, YBREAK + 3)      # 下限を40に
ax_s_top.autoscale(False)
ax_s_bot.autoscale(False)

ax_s_bot.set_yticks(list(range(40, YBREAK + 1, 20)))
ax_s_top.set_yticks([YBREAK, YTOP])

for _ax_s, ypos_s in [(ax_s_top, 0), (ax_s_bot, 1)]:
    tr_s = _ax_s.transAxes
    _ax_s.plot((-dk, +dk), (ypos_s - dk, ypos_s + dk), transform=tr_s, **bkw)
    _ax_s.plot((1-dk, 1+dk), (ypos_s - dk, ypos_s + dk), transform=tr_s, **bkw)

ax_s_bot.set_xticks(xtick_pos_s)
ax_s_bot.set_xticklabels(xtick_lbl_s, fontsize=17, rotation=45, ha="right")
ax_s_bot.set_xlabel("PAUSE 実行回数/スピン", fontsize=24)
ax_s_bot.set_ylabel("Read Latency [μs]", fontsize=24)
ax_s_bot.tick_params(axis="y", labelsize=20)
ax_s_top.tick_params(axis="y", labelsize=20)

ax_s_top.grid(True, axis="y", alpha=0.3)
ax_s_bot.grid(True, axis="y", alpha=0.3)

# 凡例: axes右端内側に縦配置（隙間なし）
struct_lines_s = [
    Line2D([0],[0], color="grey", linewidth=2.0, label="p99.9（上ひげ）"),
    mpatches.Patch(facecolor="grey", alpha=0.55, edgecolor="grey", label="p99（箱上端）"),
    mpatches.Patch(facecolor="grey", alpha=0.55, edgecolor="grey", label="p50（箱下端）"),
    Line2D([0],[0], color="grey", linewidth=2.0, label="最小値（下ひげ）"),
]
arch_handles_s = [
    mpatches.Patch(facecolor=ARCH_INFO[a]["color"], alpha=0.55,
                   edgecolor=ARCH_INFO[a]["color"],
                   label=QPS_LABEL_JA.get(a, ARCH_INFO[a]["label"]))
    for a in archs_with_utdelay
]
# subplots_adjust で axes 右端を 0.82 に設定し、
# 凡例を figure 座標 0.83 に配置 → 隙間は 1% のみ
fig_s.subplots_adjust(left=0.06, right=0.82, top=0.97, bottom=0.14)
fig_s.legend(handles=struct_lines_s + arch_handles_s, fontsize=20,
             loc="center left", bbox_to_anchor=(0.83, 0.5),
             ncol=1, framealpha=0.9)

out5 = os.path.join(OUTPUT_DIR, "latency_boxplot_slides.pdf")
fig_s.savefig(out5, dpi=150, bbox_inches="tight")
plt.close(fig_s)
print(f"Saved: {out5}")


# -------------------------------------------------------------------
# Plot 6/7: アーキ別 detail — 2段構成（関数化）
#   上段: レイテンシ箱ひげ図 (min / p50 / p99 / p999)
#   下段: スピンロック待ち時間 (p50 / p99 / p999)
#   凡例: 各パネル右外側に配置（重なり回避）
# -------------------------------------------------------------------
def _draw_detail_plot(arch, peak_n, out_path):
    if arch not in utdelay or arch not in wait:
        print(f"  [SKIP] {out_path}: data not found for {arch}")
        return False

    _di    = ARCH_INFO[arch]
    _dc    = _di["color"]
    _d_all = utdelay[arch]
    _d_min = utdelay_min[arch]
    _ns_b  = sorted(k for k in _d_all if k != "master")
    _d_w   = wait[arch]
    _ns_w  = sorted(_d_w)
    _bw    = 0.7

    fig_d, (ax_top, ax_bot) = plt.subplots(
        2, 1, figsize=(22, 14),
        gridspec_kw={"height_ratios": [5, 4], "hspace": 0.40}
    )

    # --- 上段: latency boxplot ---
    for n in _ns_b:
        dv      = _d_all[n]
        min_med  = _median([v for v in _d_min.get(n, [])     if not math.isnan(v)])
        p50_med  = _median([v for v in dv.get("r_p50",  [])  if not math.isnan(v)])
        p99_med  = _median([v for v in dv.get("r_p99",  [])  if not math.isnan(v)])
        p999_med = _median([v for v in dv.get("r_p999", [])  if not math.isnan(v)])

        if math.isnan(p50_med) or math.isnan(p99_med):
            continue

        ax_top.add_patch(plt.Rectangle(
            (n - _bw/2, p50_med), _bw, p99_med - p50_med,
            facecolor=_dc, alpha=0.6, edgecolor=_dc, linewidth=1.5
        ))
        if not math.isnan(min_med):
            ax_top.vlines(n, min_med, p50_med, color=_dc, linewidth=1.8)
            ax_top.hlines(min_med, n - _bw*0.4, n + _bw*0.4, color=_dc, linewidth=1.8)
        if not math.isnan(p999_med):
            ax_top.vlines(n, p99_med, p999_med, color=_dc, linewidth=1.8)
            ax_top.hlines(p999_med, n - _bw*0.4, n + _bw*0.4, color=_dc, linewidth=1.8)

    ax_top.axvline(peak_n, color="black", linestyle="--", linewidth=2.0, alpha=0.75)
    ax_top.annotate(f"N={peak_n}  (QPS peak)",
                    xy=(peak_n, 1), xycoords=("data", "axes fraction"),
                    xytext=(6, -6), textcoords="offset points",
                    fontsize=15, color="black", fontweight="bold", va="top")

    ax_top.set_xlim(-2, max(_ns_b) + 2)
    ax_top.tick_params(axis="x", labelsize=14)
    ax_top.tick_params(axis="y", labelsize=15)
    ax_top.set_ylabel("Read Latency [μs]", fontsize=17)
    ax_top.set_xlabel("PAUSE 実行回数/スピン", fontsize=17)
    ax_top.grid(True, axis="y", alpha=0.3)
    ax_top.autoscale_view()

    _leg_top = [
        Line2D([0],[0], color=_dc, linewidth=1.8, label="p99.9（上ひげ）"),
        mpatches.Patch(facecolor=_dc, alpha=0.6, edgecolor=_dc, label="p99（箱上端）"),
        mpatches.Patch(facecolor=_dc, alpha=0.6, edgecolor=_dc, label="p50（箱下端）"),
        Line2D([0],[0], color=_dc, linewidth=1.8, label="min（下ひげ）"),
    ]
    ax_top.legend(handles=_leg_top, fontsize=15,
                  loc="upper left", bbox_to_anchor=(1.01, 1),
                  borderaxespad=0, framealpha=0.9)

    # --- 下段: wait distribution ---
    _p50w  = [_d_w[n]["p50"]  for n in _ns_w]
    _p99w  = [_d_w[n]["p99"]  for n in _ns_w]
    _p999w = [_d_w[n]["p999"] for n in _ns_w]

    ax_bl = ax_bot
    ax_br = ax_bot.twinx()

    _nsw_arr = np.array(_ns_w, dtype=float)
    _xsw_fine = np.linspace(_nsw_arr[0], _nsw_arr[-1], 500)

    _l1, = ax_bl.plot(_xsw_fine, PchipInterpolator(_nsw_arr, _p50w)(_xsw_fine),
                      color="tab:blue",   linewidth=2.0, label="p50 (左軸)")
    ax_bl.scatter(_nsw_arr, _p50w,  color="tab:blue",   s=40, zorder=5, marker="o")

    _l2, = ax_br.plot(_xsw_fine, PchipInterpolator(_nsw_arr, _p99w)(_xsw_fine),
                      color="tab:orange", linewidth=2.0, label="p99 (右軸)")
    ax_br.scatter(_nsw_arr, _p99w,  color="tab:orange", s=40, zorder=5, marker="s")

    _l3, = ax_br.plot(_xsw_fine, PchipInterpolator(_nsw_arr, _p999w)(_xsw_fine),
                      color="tab:red",    linewidth=2.0, label="p99.9 (右軸)")
    ax_br.scatter(_nsw_arr, _p999w, color="tab:red",    s=40, zorder=5, marker="^")

    ax_bl.axvline(peak_n, color="black", linestyle="--", linewidth=2.0, alpha=0.75)
    ax_bl.annotate(f"N={peak_n}",
                   xy=(peak_n, 1), xycoords=("data", "axes fraction"),
                   xytext=(6, -6), textcoords="offset points",
                   fontsize=15, color="black", fontweight="bold", va="top")

    ax_bl.set_xlim(-2, max(_ns_w) + 2)
    ax_bl.tick_params(axis="x", labelsize=14)
    ax_bl.set_xlabel("PAUSE 実行回数/スピン", fontsize=17)
    ax_bl.set_ylabel("Spin Wait Time [μs]", fontsize=17, color="tab:blue")
    ax_br.set_ylabel("p99 / p999 [μs]",     fontsize=17, color="tab:red")
    ax_bl.tick_params(axis="y", labelsize=15, labelcolor="tab:blue")
    ax_br.tick_params(axis="y", labelsize=15, labelcolor="tab:red")
    ax_bl.grid(True, axis="y", alpha=0.3)

    ax_bl.legend(handles=[_l1, _l2, _l3], fontsize=15,
                 loc="upper left", bbox_to_anchor=(1.02, 1),
                 borderaxespad=0, framealpha=0.9)

    fig_d.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig_d)
    print(f"Saved: {out_path}")
    return True


out6 = os.path.join(OUTPUT_DIR, "skylake_detail.pdf")
_draw_detail_plot("skylake_ann", peak_n=5,
                  out_path=out6) or setattr(__builtins__, "", None)

out7 = os.path.join(OUTPUT_DIR, "icelake_detail.pdf")
_icelake_peak = peak_qps_n.get("icelake", 15)
_draw_detail_plot("icelake", peak_n=_icelake_peak,
                  out_path=out7) or setattr(__builtins__, "", None)

# -------------------------------------------------------------------
# Plot 8: icelake wait distribution のみ（単体グラフ）
# -------------------------------------------------------------------
_arch_w = "icelake"
if _arch_w in wait:
    _dw8   = wait[_arch_w]
    _ns8   = sorted(_dw8)
    _p50_8  = [_dw8[n]["p50"]  for n in _ns8]
    _p99_8  = [_dw8[n]["p99"]  for n in _ns8]
    _p999_8 = [_dw8[n]["p999"] for n in _ns8]

    fig8, ax8l = plt.subplots(figsize=(14, 6))
    ax8r = ax8l.twinx()

    _ns8_arr  = np.array(_ns8, dtype=float)
    _xs8_fine = np.linspace(_ns8_arr[0], _ns8_arr[-1], 500)

    _m1, = ax8l.plot(_xs8_fine, PchipInterpolator(_ns8_arr, _p50_8)(_xs8_fine),
                     color="tab:blue",   linewidth=2.0, label="p50 (左軸)")
    ax8l.scatter(_ns8_arr, _p50_8,  color="tab:blue",   s=40, zorder=5, marker="o")

    _m2, = ax8r.plot(_xs8_fine, PchipInterpolator(_ns8_arr, _p99_8)(_xs8_fine),
                     color="tab:orange", linewidth=2.0, label="p99 (右軸)")
    ax8r.scatter(_ns8_arr, _p99_8,  color="tab:orange", s=40, zorder=5, marker="s")

    _m3, = ax8r.plot(_xs8_fine, PchipInterpolator(_ns8_arr, _p999_8)(_xs8_fine),
                     color="tab:red",    linewidth=2.0, label="p99.9 (右軸)")
    ax8r.scatter(_ns8_arr, _p999_8, color="tab:red",    s=40, zorder=5, marker="^")

    ax8l.axvline(_icelake_peak, color="black", linestyle="--", linewidth=2.0, alpha=0.75)
    ax8l.annotate(f"N={_icelake_peak}",
                  xy=(_icelake_peak, 1), xycoords=("data", "axes fraction"),
                  xytext=(6, -6), textcoords="offset points",
                  fontsize=15, color="black", fontweight="bold", va="top")

    ax8l.set_xlim(-2, max(_ns8) + 2)
    ax8l.set_xlabel("PAUSE 実行回数/スピン", fontsize=17)
    ax8l.set_ylabel("Spin Wait Time [μs]", fontsize=17, color="tab:blue")
    ax8r.set_ylabel("p99 / p99.9 [μs]",    fontsize=17, color="tab:red")
    ax8l.tick_params(axis="x", labelsize=14)
    ax8l.tick_params(axis="y", labelsize=15, labelcolor="tab:blue")
    ax8r.tick_params(axis="y", labelsize=15, labelcolor="tab:red")
    ax8l.grid(True, axis="y", alpha=0.3)

    ax8l.legend(handles=[_m1, _m2, _m3], fontsize=15,
                loc="upper left", bbox_to_anchor=(1.18, 1),
                ncol=1, borderaxespad=0, framealpha=0.9)

    out8 = os.path.join(OUTPUT_DIR, "icelake_wait_dist.pdf")
    fig8.savefig(out8, dpi=150, bbox_inches="tight")
    plt.close(fig8)
    print(f"Saved: {out8}")
else:
    out8 = None
    print("  [SKIP] icelake_wait_dist: icelake wait data not found")


print("\nDone.")
print(f"  {out1}")
print(f"  {out1c}")
print(f"  {out1b}")
print(f"  {out2}")
print(f"  {out2b}")
print(f"  {out2c}")
print(f"  {out3}")
for p in out4_paths:
    print(f"  {p}")
print(f"  {out5}")
print(f"  {out6}")
print(f"  {out7}")
if out8:
    print(f"  {out8}")
