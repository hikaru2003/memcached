#!/usr/bin/env python3
# Usage:
#   cd /home/morisaki/Application/memcached
#   python3 experiment/plot_pause_sweep.py [result_dir]
#
# Output:
#   {result_dir}/plots/qps.png
#   {result_dir}/plots/latency_read.png
#   {result_dir}/plots/latency_write.png
#
# Prerequisites:
#   pip install matplotlib pandas

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

# master_baseline と pause_X を分離
master = df[df["label"] == "master_baseline"]
pause_df = df[df["label"].str.startswith("pause_")].copy()
pause_df["pause_count"] = pause_df["label"].str.replace("pause_", "").astype(int)

# 各 PAUSE 値ごとに統計を集計
stats = pause_df.groupby("pause_count").agg(
    qps_mean=("QPS", "mean"),
    qps_std=("QPS", "std"),
    r_avg_mean=("r_avg_us", "mean"),
    r_p99_mean=("r_p99_us", "mean"),
    w_avg_mean=("w_avg_us", "mean"),
    w_p99_mean=("w_p99_us", "mean"),
).reset_index().sort_values("pause_count")

# master baseline の統計
m_qps_mean = master["QPS"].mean()
m_qps_std  = master["QPS"].std()
m_r_avg    = master["r_avg_us"].mean()
m_r_p99    = master["r_p99_us"].mean()
m_w_avg    = master["w_avg_us"].mean()
m_w_p99    = master["w_p99_us"].mean()

x = stats["pause_count"].values

STYLE = dict(fontsize=11)
MASTER_COLOR = "#e15759"
PAUSE_COLOR  = "#4e79a7"

# ─────────────────────────────────────────
# 1. QPS グラフ（±1σ エラーバー）
# ─────────────────────────────────────────
fig, ax = plt.subplots(figsize=(12, 5))

ax.errorbar(
    x, stats["qps_mean"].values,
    yerr=stats["qps_std"].values,
    fmt="o-", color=PAUSE_COLOR, linewidth=1.8, markersize=5,
    capsize=4, elinewidth=1.2, label="pause-spinlock (mean ± 1σ)"
)
ax.axhline(m_qps_mean, color=MASTER_COLOR, linestyle="--", linewidth=1.5,
           label=f"master baseline  mean={m_qps_mean/1e3:.0f}k QPS")
ax.axhspan(m_qps_mean - m_qps_std, m_qps_mean + m_qps_std,
           color=MASTER_COLOR, alpha=0.12)

ax.set_xlabel("PAUSE_COUNT", **STYLE)
ax.set_ylabel("QPS", **STYLE)
ax.set_title("QPS vs PAUSE_COUNT  (d=32, 4conn, r=1, u=0.5, n=10)", **STYLE)
ax.set_xticks(x)
ax.xaxis.set_tick_params(labelsize=9)
ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{v/1e3:.0f}k"))
ax.legend(fontsize=10)
ax.grid(True, alpha=0.35)
_qps_all = np.concatenate([stats["qps_mean"].values,
                            [m_qps_mean - m_qps_std, m_qps_mean + m_qps_std]])
_margin = (_qps_all.max() - _qps_all.min()) * 0.1
ax.set_ylim(_qps_all.min() - _margin, _qps_all.max() + _margin)

fig.tight_layout()
out = os.path.join(PLOT_DIR, "qps.png")
fig.savefig(out, dpi=150)
print(f"saved: {out}")
plt.close(fig)

# ─────────────────────────────────────────
# 2. READ レイテンシ（avg / p99）
# ─────────────────────────────────────────
fig, ax = plt.subplots(figsize=(12, 5))

ax.plot(x, stats["r_avg_mean"].values, "o-", color=PAUSE_COLOR,
        linewidth=1.8, markersize=5, label="read avg (pause-spinlock)")
ax.plot(x, stats["r_p99_mean"].values, "s--", color=PAUSE_COLOR,
        linewidth=1.5, markersize=5, alpha=0.7, label="read p99 (pause-spinlock)")

ax.axhline(m_r_avg, color=MASTER_COLOR, linestyle="-", linewidth=1.5,
           label=f"master read avg  {m_r_avg:.1f} µs")
ax.axhline(m_r_p99, color=MASTER_COLOR, linestyle="--", linewidth=1.5,
           alpha=0.7, label=f"master read p99  {m_r_p99:.1f} µs")

ax.set_xlabel("PAUSE_COUNT", **STYLE)
ax.set_ylabel("Latency (µs)", **STYLE)
ax.set_title("Read Latency vs PAUSE_COUNT  (avg / p99)", **STYLE)
ax.set_xticks(x)
ax.xaxis.set_tick_params(labelsize=9)
ax.legend(fontsize=10)
ax.grid(True, alpha=0.35)

fig.tight_layout()
out = os.path.join(PLOT_DIR, "latency_read.png")
fig.savefig(out, dpi=150)
print(f"saved: {out}")
plt.close(fig)

# ─────────────────────────────────────────
# 3. WRITE（UPDATE）レイテンシ（avg / p99）
# ─────────────────────────────────────────
WRITE_COLOR = "#59a14f"

fig, ax = plt.subplots(figsize=(12, 5))

ax.plot(x, stats["w_avg_mean"].values, "o-", color=WRITE_COLOR,
        linewidth=1.8, markersize=5, label="write avg (pause-spinlock)")
ax.plot(x, stats["w_p99_mean"].values, "s--", color=WRITE_COLOR,
        linewidth=1.5, markersize=5, alpha=0.7, label="write p99 (pause-spinlock)")

ax.axhline(m_w_avg, color=MASTER_COLOR, linestyle="-", linewidth=1.5,
           label=f"master write avg  {m_w_avg:.1f} µs")
ax.axhline(m_w_p99, color=MASTER_COLOR, linestyle="--", linewidth=1.5,
           alpha=0.7, label=f"master write p99  {m_w_p99:.1f} µs")

ax.set_xlabel("PAUSE_COUNT", **STYLE)
ax.set_ylabel("Latency (µs)", **STYLE)
ax.set_title("Write Latency vs PAUSE_COUNT  (avg / p99)", **STYLE)
ax.set_xticks(x)
ax.xaxis.set_tick_params(labelsize=9)
ax.legend(fontsize=10)
ax.grid(True, alpha=0.35)

fig.tight_layout()
out = os.path.join(PLOT_DIR, "latency_write.png")
fig.savefig(out, dpi=150)
print(f"saved: {out}")
plt.close(fig)

print("done.")
