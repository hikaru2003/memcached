#!/usr/bin/env python3
# Usage:
#   cd /home/morisaki/Application/memcached
#   python3 experiment/plot_utdelay_vs_pause.py
#
# Description:
#   pause-spinlock (pause_d32_mc4_mut4_run2) と utdelay (utdelay_sweep_20260618_135202)
#   を「total PAUSE budget」の共通X軸で比較する。
#
#   total_pause_budget:
#     - pause-spinlock pause=N: [trylock -> 1 PAUSE] x N  → total = N
#     - utdelay N=3, rounds=30: [trylock -> 3 PAUSE] x 30 → total = 90
#
# Output:
#   experiment/graphs/utdelay_vs_pause_qps.png
#   experiment/graphs/utdelay_vs_pause_latency.png
#
# Prerequisites:
#   pip install matplotlib pandas

import os
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

PAUSE_DIR   = "experiment/results/pause_d32_mc4_mut4_run2"
UTDELAY_DIR = "experiment/results/utdelay_sweep_20260618_135202"
OUT_DIR     = "experiment/graphs"
os.makedirs(OUT_DIR, exist_ok=True)

# ── pause-spinlock data ──────────────────────────────────────────
p_df = pd.read_csv(os.path.join(PAUSE_DIR, "raw.csv"))

master_rows = p_df[p_df["label"] == "master_baseline"]
m_qps_mean = master_rows["QPS"].mean()
m_qps_std  = master_rows["QPS"].std()
m_r_avg    = master_rows["r_avg_us"].mean()
m_r_p99    = master_rows["r_p99_us"].mean()
m_w_avg    = master_rows["w_avg_us"].mean()
m_w_p99    = master_rows["w_p99_us"].mean()

pause_rows = p_df[p_df["label"].str.startswith("pause_")].copy()
pause_rows["total_pause_budget"] = pause_rows["label"].str.replace("pause_", "").astype(int)

p_stats = pause_rows.groupby("total_pause_budget").agg(
    qps_mean=("QPS", "mean"),
    qps_std=("QPS", "std"),
    r_avg_mean=("r_avg_us", "mean"),
    r_p99_mean=("r_p99_us", "mean"),
    w_avg_mean=("w_avg_us", "mean"),
    w_p99_mean=("w_p99_us", "mean"),
).reset_index().sort_values("total_pause_budget")

# ── utdelay data ─────────────────────────────────────────────────
u_df = pd.read_csv(os.path.join(UTDELAY_DIR, "raw.csv"))
u_stats = u_df.groupby("total_pause_budget").agg(
    qps_mean=("QPS", "mean"),
    qps_std=("QPS", "std"),
    r_avg_mean=("r_avg_us", "mean"),
    r_p99_mean=("r_p99_us", "mean"),
    w_avg_mean=("w_avg_us", "mean"),
    w_p99_mean=("w_p99_us", "mean"),
).reset_index().sort_values("total_pause_budget")

# ── colors ───────────────────────────────────────────────────────
C_PAUSE   = "#4e79a7"
C_UTDELAY = "#f28e2b"
C_MASTER  = "#e15759"

STYLE = dict(fontsize=11)

# ═══════════════════════════════════════════════════════════════
# 1. QPS vs total PAUSE budget
# ═══════════════════════════════════════════════════════════════
fig, ax = plt.subplots(figsize=(13, 5))

px = p_stats["total_pause_budget"].values
ax.errorbar(
    px, p_stats["qps_mean"].values,
    yerr=p_stats["qps_std"].values,
    fmt="o-", color=C_PAUSE, linewidth=1.8, markersize=4,
    capsize=3, elinewidth=1.0,
    label="pause-spinlock  [trylock→1PAUSE]×N  (mean±1σ, n=10)"
)

# utdelay points (star marker, larger)
ux = u_stats["total_pause_budget"].values
uy = u_stats["qps_mean"].values
ue = u_stats["qps_std"].values
ax.errorbar(
    ux, uy, yerr=ue,
    fmt="*", color=C_UTDELAY, markersize=16,
    capsize=4, elinewidth=1.5,
    label="utdelay  [trylock→3PAUSE]×30  (mean±1σ, n=10)"
)

# utdelay value annotation
for xi, yi in zip(ux, uy):
    ax.annotate(
        f"{yi/1e3:.0f}k",
        xy=(xi, yi), xytext=(xi + 15, yi + 12000),
        fontsize=9, color=C_UTDELAY,
        arrowprops=dict(arrowstyle="->", color=C_UTDELAY, lw=0.8)
    )

ax.axhline(m_qps_mean, color=C_MASTER, linestyle="--", linewidth=1.5,
           label=f"master (pthread_mutex only)  {m_qps_mean/1e3:.0f}k QPS")
ax.axhspan(m_qps_mean - m_qps_std, m_qps_mean + m_qps_std,
           color=C_MASTER, alpha=0.10)

ax.set_xlabel("Total PAUSE budget per spin attempt", **STYLE)
ax.set_ylabel("QPS", **STYLE)
ax.set_title(
    "QPS vs Total PAUSE Budget — pause-spinlock vs MySQL ut_delay\n"
    "(mc=4, -T4 -c1 -d32 -r1 -u0.5, duration=60s, n=10)",
    **STYLE
)
ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{v/1e3:.0f}k"))
ax.legend(fontsize=9, loc="lower right")
ax.grid(True, alpha=0.35)

_all = np.concatenate([p_stats["qps_mean"].values, uy,
                        [m_qps_mean - m_qps_std, m_qps_mean + m_qps_std]])
_mg = (_all.max() - _all.min()) * 0.12
ax.set_ylim(_all.min() - _mg, _all.max() + _mg)

fig.tight_layout()
out = os.path.join(OUT_DIR, "utdelay_vs_pause_qps.png")
fig.savefig(out, dpi=150)
print(f"saved: {out}")
plt.close(fig)

# ═══════════════════════════════════════════════════════════════
# 2. Read Latency (avg / p99)
# ═══════════════════════════════════════════════════════════════
fig, ax = plt.subplots(figsize=(13, 5))

ax.plot(px, p_stats["r_avg_mean"].values, "o-", color=C_PAUSE,
        linewidth=1.8, markersize=4, label="pause-spinlock read avg")
ax.plot(px, p_stats["r_p99_mean"].values, "s--", color=C_PAUSE,
        linewidth=1.5, markersize=4, alpha=0.65, label="pause-spinlock read p99")

ax.errorbar(ux, u_stats["r_avg_mean"].values, yerr=u_stats["qps_std"].values * 0,
            fmt="*", color=C_UTDELAY, markersize=14,
            label=f"utdelay N=3 read avg  {u_stats['r_avg_mean'].values[0]:.1f}µs")
ax.plot(ux, u_stats["r_p99_mean"].values, "*", color=C_UTDELAY,
        markersize=10, alpha=0.65,
        label=f"utdelay N=3 read p99  {u_stats['r_p99_mean'].values[0]:.1f}µs")

ax.axhline(m_r_avg, color=C_MASTER, linestyle="-", linewidth=1.5,
           label=f"master read avg  {m_r_avg:.1f}µs")
ax.axhline(m_r_p99, color=C_MASTER, linestyle="--", linewidth=1.5,
           alpha=0.7, label=f"master read p99  {m_r_p99:.1f}µs")

ax.set_xlabel("Total PAUSE budget per spin attempt", **STYLE)
ax.set_ylabel("Latency (µs)", **STYLE)
ax.set_title(
    "Read Latency vs Total PAUSE Budget — pause-spinlock vs MySQL ut_delay",
    **STYLE
)
ax.legend(fontsize=9)
ax.grid(True, alpha=0.35)

fig.tight_layout()
out = os.path.join(OUT_DIR, "utdelay_vs_pause_latency.png")
fig.savefig(out, dpi=150)
print(f"saved: {out}")
plt.close(fig)

print("done.")
