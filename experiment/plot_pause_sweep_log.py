#!/usr/bin/env python3
# Usage:
#   cd /home/morisaki/Application/memcached
#   python3 experiment/plot_pause_sweep_log.py [result_dir]
#
# Output:
#   {result_dir}/plots/qps_log.png
#   {result_dir}/plots/latency_read_log.png
#   {result_dir}/plots/latency_write_log.png

import sys
import os
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

RESULT_DIR = sys.argv[1] if len(sys.argv) > 1 else \
    "experiment/results/pause_d32_sweep_t4_T4_run2"
CSV_PATH = os.path.join(RESULT_DIR, "raw.csv")
PLOT_DIR = os.path.join(RESULT_DIR, "plots")
os.makedirs(PLOT_DIR, exist_ok=True)

df = pd.read_csv(CSV_PATH)

master = df[df["label"] == "master_baseline"]
pause_df = df[df["label"].str.startswith("pause_")].copy()
pause_df["pause_count"] = pause_df["label"].str.replace("pause_", "").astype(int)

stats = pause_df.groupby("pause_count").agg(
    qps_mean=("QPS", "mean"),
    qps_std=("QPS", "std"),
    r_avg_mean=("r_avg_us", "mean"),
    r_p99_mean=("r_p99_us", "mean"),
    w_avg_mean=("w_avg_us", "mean"),
    w_p99_mean=("w_p99_us", "mean"),
).reset_index().sort_values("pause_count")

m_qps_mean = master["QPS"].mean()
m_qps_std  = master["QPS"].std()
m_r_avg    = master["r_avg_us"].mean()
m_r_p99    = master["r_p99_us"].mean()
m_w_avg    = master["w_avg_us"].mean()
m_w_p99    = master["w_p99_us"].mean()

x = stats["pause_count"].values

# symlog: PAUSE_COUNT=0 を軸に乗せるため linthresh=5 を使用
# 0 は線形領域に、10以上は対数スケールで表示される
LINTHRESH = 5
XTICKS = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]

STYLE = dict(fontsize=11)
MASTER_COLOR = "#e15759"
PAUSE_COLOR  = "#4e79a7"
WRITE_COLOR  = "#59a14f"

def apply_log_xaxis(ax):
    ax.set_xscale("symlog", linthresh=LINTHRESH)
    ax.set_xticks(XTICKS)
    ax.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
    ax.tick_params(axis='x', labelsize=8, rotation=45)
    ax.set_xlim(-2, 1100)

# ─────────────────────────────────────────
# 1. QPS（対数スケール + エラーバー値表示）
# ─────────────────────────────────────────
fig, ax = plt.subplots(figsize=(13, 6))

eb = ax.errorbar(
    x, stats["qps_mean"].values,
    yerr=stats["qps_std"].values,
    fmt="o-", color=PAUSE_COLOR, linewidth=1.8, markersize=5,
    capsize=4, elinewidth=1.2, label="pause-spinlock (mean ± 1σ)"
)

# エラーバー値をテキストで表示（上キャップの上に ±Xk 形式）
for xi, mean, std in zip(x, stats["qps_mean"].values, stats["qps_std"].values):
    label_text = f"±{std/1e3:.1f}k"
    ax.annotate(
        label_text,
        xy=(xi, mean + std),
        xytext=(0, 4),
        textcoords="offset points",
        ha="center", va="bottom",
        fontsize=6.5, color=PAUSE_COLOR, rotation=70,
    )

ax.axhline(m_qps_mean, color=MASTER_COLOR, linestyle="--", linewidth=1.5,
           label=f"master baseline  mean={m_qps_mean/1e3:.0f}k  ±{m_qps_std/1e3:.1f}k")
ax.axhspan(m_qps_mean - m_qps_std, m_qps_mean + m_qps_std,
           color=MASTER_COLOR, alpha=0.12)

apply_log_xaxis(ax)
ax.set_xlabel("PAUSE_COUNT  (symlog scale)", **STYLE)
ax.set_ylabel("QPS", **STYLE)
ax.set_title("QPS vs PAUSE_COUNT  (d=32, 4conn, r=1, u=0.5, n=10)", **STYLE)
ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{v/1e3:.0f}k"))
ax.legend(fontsize=10)
ax.grid(True, alpha=0.35, which="both")
_qps_all = np.concatenate([stats["qps_mean"].values,
                            [m_qps_mean - m_qps_std, m_qps_mean + m_qps_std]])
_margin = (_qps_all.max() - _qps_all.min()) * 0.1
ax.set_ylim(_qps_all.min() - _margin, _qps_all.max() + _margin)

fig.tight_layout()
out = os.path.join(PLOT_DIR, "qps_log.png")
fig.savefig(out, dpi=150)
print(f"saved: {out}")
plt.close(fig)

# ─────────────────────────────────────────
# 2. READ レイテンシ（対数スケール）
# ─────────────────────────────────────────
fig, ax = plt.subplots(figsize=(13, 6))

ax.plot(x, stats["r_avg_mean"].values, "o-", color=PAUSE_COLOR,
        linewidth=1.8, markersize=5, label="read avg (pause-spinlock)")
ax.plot(x, stats["r_p99_mean"].values, "s--", color=PAUSE_COLOR,
        linewidth=1.5, markersize=5, alpha=0.7, label="read p99 (pause-spinlock)")

# avg の値ラベル
for xi, v in zip(x, stats["r_avg_mean"].values):
    ax.annotate(f"{v:.1f}", xy=(xi, v), xytext=(0, 5),
                textcoords="offset points",
                ha="center", va="bottom", fontsize=6.5, color=PAUSE_COLOR, rotation=70)

ax.axhline(m_r_avg, color=MASTER_COLOR, linestyle="-", linewidth=1.5,
           label=f"master read avg  {m_r_avg:.1f} µs")
ax.axhline(m_r_p99, color=MASTER_COLOR, linestyle="--", linewidth=1.5,
           alpha=0.7, label=f"master read p99  {m_r_p99:.1f} µs")

apply_log_xaxis(ax)
ax.set_xlabel("PAUSE_COUNT  (symlog scale)", **STYLE)
ax.set_ylabel("Latency (µs)", **STYLE)
ax.set_title("Read Latency vs PAUSE_COUNT  (avg / p99)", **STYLE)
ax.legend(fontsize=10)
ax.grid(True, alpha=0.35, which="both")

fig.tight_layout()
out = os.path.join(PLOT_DIR, "latency_read_log.png")
fig.savefig(out, dpi=150)
print(f"saved: {out}")
plt.close(fig)

# ─────────────────────────────────────────
# 3. WRITE レイテンシ（対数スケール）
# ─────────────────────────────────────────
fig, ax = plt.subplots(figsize=(13, 6))

ax.plot(x, stats["w_avg_mean"].values, "o-", color=WRITE_COLOR,
        linewidth=1.8, markersize=5, label="write avg (pause-spinlock)")
ax.plot(x, stats["w_p99_mean"].values, "s--", color=WRITE_COLOR,
        linewidth=1.5, markersize=5, alpha=0.7, label="write p99 (pause-spinlock)")

for xi, v in zip(x, stats["w_avg_mean"].values):
    ax.annotate(f"{v:.1f}", xy=(xi, v), xytext=(0, 5),
                textcoords="offset points",
                ha="center", va="bottom", fontsize=6.5, color=WRITE_COLOR, rotation=70)

ax.axhline(m_w_avg, color=MASTER_COLOR, linestyle="-", linewidth=1.5,
           label=f"master write avg  {m_w_avg:.1f} µs")
ax.axhline(m_w_p99, color=MASTER_COLOR, linestyle="--", linewidth=1.5,
           alpha=0.7, label=f"master write p99  {m_w_p99:.1f} µs")

apply_log_xaxis(ax)
ax.set_xlabel("PAUSE_COUNT  (symlog scale)", **STYLE)
ax.set_ylabel("Latency (µs)", **STYLE)
ax.set_title("Write Latency vs PAUSE_COUNT  (avg / p99)", **STYLE)
ax.legend(fontsize=10)
ax.grid(True, alpha=0.35, which="both")

fig.tight_layout()
out = os.path.join(PLOT_DIR, "latency_write_log.png")
fig.savefig(out, dpi=150)
print(f"saved: {out}")
plt.close(fig)

print("done.")
