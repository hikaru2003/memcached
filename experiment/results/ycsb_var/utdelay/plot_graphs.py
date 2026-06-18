"""
Usage:
    cd experiment/results/ycsb_var_utdelay
    python3 plot_graphs.py

Description:
    ycsb_var_utdelay の summary.md からグラフを生成する。
    ベースライン: ../ycsb_var_master_baseline/summary.md の master branch 値

Output:
    graph_overview.png  -- 3パネル (gain%, read avg latency, write avg latency)

Parameters:
    summary.md から pause_per_round 値を自動検出

Prerequisites:
    pip install matplotlib numpy
    summary.md と ../ycsb_var_master_baseline/summary.md が存在すること
"""

import os
import re
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

BASE_DIR   = os.path.dirname(os.path.abspath(__file__))
SUMMARY    = os.path.join(BASE_DIR, 'summary.md')
MASTER_SUM = os.path.join(BASE_DIR, '..', 'ycsb_var_master_baseline', 'summary.md')


def parse_utdelay_summary(path):
    """
    ycsb_var_utdelay/summary.md format:
    | pause_per_round | mean_OPS | ... | read_avg_us | update_avg_us | n |
    """
    rows = []
    with open(path) as f:
        for line in f:
            m = re.match(
                r'\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|\s*[\d.]+\s*\|\s*[\d.]+\s*\|'
                r'\s*[\d.]+\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|', line)
            if m:
                rows.append({
                    'n':       int(m.group(1)),
                    'mean_OPS': float(m.group(2)),
                    'r_avg':   float(m.group(3)),
                    'w_avg':   float(m.group(4)),
                })
    return rows


def parse_master_baseline(path):
    """
    ycsb_var_master_baseline/summary.md format:
    | master_baseline | mean_OPS | ... | read_avg_us | update_avg_us | n |
    """
    with open(path) as f:
        for line in f:
            m = re.match(
                r'\|\s*master_baseline\s*\|\s*([\d.]+)\s*\|\s*[\d.]+\s*\|\s*[\d.]+\s*\|'
                r'\s*[\d.]+\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|', line)
            if m:
                return float(m.group(1)), float(m.group(2)), float(m.group(3))
    return None, None, None


def set_xticks(ax, labels):
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, fontsize=9)


def vline_master(ax):
    ax.axvline(0.5, color='gray', linestyle=':', linewidth=1.0, alpha=0.5)


rows = parse_utdelay_summary(SUMMARY)
m_ops, m_r_avg, m_w_avg = parse_master_baseline(MASTER_SUM)

ns    = [r['n']        for r in rows]
ops   = [r['mean_OPS'] for r in rows]
r_avg = [r['r_avg']    for r in rows]
w_avg = [r['w_avg']    for r in rows]

# prepend master as leftmost point
gain  = [0.0] + [(o - m_ops) / m_ops * 100 for o in ops]
r_avg = [m_r_avg] + r_avg
w_avg = [m_w_avg] + w_avg
labels = ['master'] + [str(n) for n in ns]
xs = list(range(len(labels)))

COLOR = '#e91e63'

fig, axes = plt.subplots(1, 3, figsize=(21, 5))
fig.suptitle(
    'ut_delay effect — YCSB VAR workload  [Zipf s=1.107, 82% SET, 100k keys, 500B, -t 32, ycsb_threads=16]\n'
    'Baseline: master branch (no spinlock)',
    fontsize=13, fontweight='bold')

ax = axes[0]
ax.plot(xs, gain, marker='o', markersize=5, linewidth=2, color=COLOR)
ax.axhline(0, color='black', linestyle='--', linewidth=1.2, alpha=0.6,
           label=f'master ({m_ops/1000:.1f}k OPS)')
vline_master(ax)
for xi, g in zip(xs, gain):
    ax.annotate(f'{g:+.1f}%', (xi, g),
                textcoords='offset points', xytext=(0, 8 if g >= 0 else -14),
                ha='center', fontsize=7.5)
set_xticks(ax, labels)
ax.set_xlabel('pause_per_round', fontsize=10)
ax.set_ylabel('Throughput gain vs master (%)', fontsize=10)
ax.set_title('Throughput gain%', fontsize=11, fontweight='bold')
ax.legend(fontsize=8)
ax.grid(True, alpha=0.3)

ax = axes[1]
ax.plot(xs, r_avg, marker='o', markersize=5, linewidth=2, color=COLOR, label='read avg')
vline_master(ax)
set_xticks(ax, labels)
ax.set_xlabel('pause_per_round', fontsize=10)
ax.set_ylabel('Read avg latency (µs)', fontsize=10)
ax.set_title('Read avg latency', fontsize=11, fontweight='bold')
ax.legend(fontsize=9)
ax.grid(True, alpha=0.3)

ax = axes[2]
ax.plot(xs, w_avg, marker='s', markersize=5, linewidth=2, color=COLOR, linestyle='--',
        label='write avg')
vline_master(ax)
set_xticks(ax, labels)
ax.set_xlabel('pause_per_round', fontsize=10)
ax.set_ylabel('Write avg latency (µs)', fontsize=10)
ax.set_title('Write avg latency', fontsize=11, fontweight='bold')
ax.legend(fontsize=9)
ax.grid(True, alpha=0.3)

plt.tight_layout()
out = os.path.join(BASE_DIR, 'graph_overview.png')
fig.savefig(out, dpi=150, bbox_inches='tight')
plt.close(fig)
print(f'saved: {out}')
print('done.')
