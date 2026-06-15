"""
Usage:
    cd experiment/results/utdelay_sweep
    python3 plot_graphs.py

Description:
    utdelay_sweep の summary.md からグラフを生成する。
    ベースライン: pause_per_round=0

Output:
    graph_overview.png  -- 3パネル (gain%, avg latency, p99 latency)

Parameters:
    summary.md から pause_per_round 値を自動検出

Prerequisites:
    pip install matplotlib numpy
    summary.md が存在すること (update_summaries.py 実行済み)
"""

import os
import re
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SUMMARY = os.path.join(BASE_DIR, 'summary.md')


def parse_summary(path):
    rows = []
    with open(path) as f:
        for line in f:
            m = re.match(
                r'\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|\s*[\d.]+\s*\|\s*[\d.]+\s*\|'
                r'\s*[\d.]+\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|'
                r'\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|', line)
            if m:
                rows.append({
                    'n':        int(m.group(1)),
                    'mean_QPS': float(m.group(2)),
                    'r_avg':    float(m.group(3)),
                    'r_p99':    float(m.group(4)),
                    'w_avg':    float(m.group(5)),
                    'w_p99':    float(m.group(6)),
                })
    return rows


def set_xticks(ax, labels):
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, fontsize=9)


rows = parse_summary(SUMMARY)
ns      = [r['n']        for r in rows]
qps     = [r['mean_QPS'] for r in rows]
r_avg   = [r['r_avg']    for r in rows]
r_p99   = [r['r_p99']    for r in rows]
w_avg   = [r['w_avg']    for r in rows]
w_p99   = [r['w_p99']    for r in rows]

base_qps = qps[0]
gain = [(q - base_qps) / base_qps * 100 for q in qps]
labels = [str(n) for n in ns]
xs = list(range(len(ns)))

COLOR = '#9467bd'

fig, axes = plt.subplots(1, 3, figsize=(21, 5))
fig.suptitle(
    'ut_delay effect — utdelay_sweep  [mysql-like-utdelay, spin_rounds=30, -r 1, -u 0.5, -t 32]\n'
    'Baseline: pause_per_round=0',
    fontsize=13, fontweight='bold')

ax = axes[0]
ax.plot(xs, gain, marker='o', markersize=5, linewidth=2, color=COLOR)
ax.axhline(0, color='black', linestyle='--', linewidth=1.2, alpha=0.6,
           label=f'N=0 ({base_qps/1000:.1f}k QPS)')
for xi, g in zip(xs, gain):
    ax.annotate(f'{g:+.1f}%', (xi, g),
                textcoords='offset points', xytext=(0, 8 if g >= 0 else -14),
                ha='center', fontsize=7.5)
set_xticks(ax, labels)
ax.set_xlabel('pause_per_round', fontsize=10)
ax.set_ylabel('Throughput gain vs N=0 (%)', fontsize=10)
ax.set_title('Throughput gain%', fontsize=11, fontweight='bold')
ax.legend(fontsize=8)
ax.grid(True, alpha=0.3)

ax = axes[1]
ax.plot(xs, r_avg, marker='o', markersize=5, linewidth=2, color=COLOR, label='read avg')
ax.plot(xs, w_avg, marker='s', markersize=5, linewidth=2, color=COLOR,
        linestyle='--', label='write avg')
set_xticks(ax, labels)
ax.set_xlabel('pause_per_round', fontsize=10)
ax.set_ylabel('Avg latency (µs)', fontsize=10)
ax.set_title('Avg latency', fontsize=11, fontweight='bold')
ax.legend(fontsize=9)
ax.grid(True, alpha=0.3)

ax = axes[2]
ax.plot(xs, r_p99, marker='o', markersize=5, linewidth=2, color=COLOR, label='read p99')
ax.plot(xs, w_p99, marker='s', markersize=5, linewidth=2, color=COLOR,
        linestyle='--', label='write p99')
set_xticks(ax, labels)
ax.set_xlabel('pause_per_round', fontsize=10)
ax.set_ylabel('p99 latency (µs)', fontsize=10)
ax.set_title('p99 latency', fontsize=11, fontweight='bold')
ax.legend(fontsize=9)
ax.grid(True, alpha=0.3)

plt.tight_layout()
out = os.path.join(BASE_DIR, 'graph_overview.png')
fig.savefig(out, dpi=150, bbox_inches='tight')
plt.close(fig)
print(f'saved: {out}')
print('done.')
