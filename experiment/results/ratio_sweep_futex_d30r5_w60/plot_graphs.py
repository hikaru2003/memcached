"""
Usage:
    cd experiment/results/ratio_sweep_futex_d30r5_w60
    python3 plot_graphs.py

Output:
    graph_overview.png          -- all ratios, 2x3 panels
                                   row0: throughput gain%, read avg, write avg
                                   row1: (hidden),         read p99,  write p99
    per_ratio/graph_{ratio}.png -- per-ratio: gain% + avg latency (read+write) + p99 (read+write)

    Old graph_{ratio}.png files at this directory level are deleted on each run.

Parameters:
    PAUSE_VALUES  -- pause_count sweep values (x-axis, leftmost = master baseline)
    RATIOS        -- GET:SET ratio subdirectory names

Prerequisites:
    pip install matplotlib numpy
    master_baseline/summary.md and master_baseline/run_*.log must exist
    get*/run_P{pause}_{run}.log must exist
"""

import os
import re
import glob
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

RATIOS = [
    'get100_set0', 'get90_set10', 'get70_set30', 'get50_set50',
    'get30_set70', 'get10_set90', 'get0_set100',
]

RATIO_COLORS = [
    '#1f77b4', '#ff7f0e', '#2ca02c', '#d62728',
    '#9467bd', '#8c564b', '#e377c2',
]

PAUSE_VALUES = [0, 10, 30, 50, 70, 100]
X_LABELS = ['master'] + [str(p) for p in PAUSE_VALUES]


# ---- parsers ----

def parse_latency_from_logs(logs, metric='read'):
    """Mean avg_us and p99_us for 'read' or 'update' from a list of log files."""
    avgs, p99s = [], []
    for log in logs:
        with open(log) as f:
            for line in f:
                if line.startswith(metric + ' ') or line.startswith(metric + '\t'):
                    parts = line.split()
                    if len(parts) >= 9:
                        avgs.append(float(parts[1]))
                        p99s.append(float(parts[8]))
                    break
    if not avgs:
        return 0.0, 0.0
    return sum(avgs) / len(avgs), sum(p99s) / len(p99s)


def parse_sub_summary_qps(path):
    data = {}
    with open(path) as f:
        for line in f:
            m = re.match(r'\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|', line)
            if m:
                data[int(m.group(1))] = float(m.group(2))
    return data


def parse_master_baseline_qps(path):
    data = {}
    with open(path) as f:
        for line in f:
            m = re.match(r'\|\s*(get\d+_set\d+)\s*\|\s*([\d.]+)\s*\|', line)
            if m:
                data[m.group(1)] = float(m.group(2))
    return data


def set_xticks(ax, labels):
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, fontsize=9)


def vline_master(ax):
    ax.axvline(0.5, color='gray', linestyle=':', linewidth=1.0, alpha=0.5)


# ---- delete old top-level graph_{ratio}.png ----

for ratio in RATIOS:
    old = os.path.join(BASE_DIR, f'graph_{ratio}.png')
    if os.path.exists(old):
        os.remove(old)
        print(f'deleted: {old}')

# ---- load all data ----

master_qps = parse_master_baseline_qps(
    os.path.join(BASE_DIR, 'master_baseline', 'summary.md'))

all_data = {}
for ratio in RATIOS:
    sub_dir = os.path.join(BASE_DIR, ratio)
    sub_path = os.path.join(sub_dir, 'summary.md')
    if not os.path.exists(sub_path):
        print(f'[skip] {ratio}: not found')
        continue

    qps_by_pc = parse_sub_summary_qps(sub_path)
    m_qps = master_qps[ratio]

    # master baseline latency (from master_baseline logs)
    mb_logs = sorted(glob.glob(
        os.path.join(BASE_DIR, 'master_baseline', f'run_{ratio}_*.log')))
    m_r_avg, m_r_p99 = parse_latency_from_logs(mb_logs, 'read')
    m_w_avg, m_w_p99 = parse_latency_from_logs(mb_logs, 'update')

    # per pause_count latency (from sub-ratio logs)
    r_avg_list, r_p99_list = [m_r_avg], [m_r_p99]
    w_avg_list, w_p99_list = [m_w_avg], [m_w_p99]
    gain_list = [0.0]

    for pc in PAUSE_VALUES:
        logs = sorted(glob.glob(os.path.join(sub_dir, f'run_P{pc}_*.log')))
        r_avg, r_p99 = parse_latency_from_logs(logs, 'read')
        w_avg, w_p99 = parse_latency_from_logs(logs, 'update')
        r_avg_list.append(r_avg)
        r_p99_list.append(r_p99)
        w_avg_list.append(w_avg)
        w_p99_list.append(w_p99)
        gain = (qps_by_pc.get(pc, m_qps) - m_qps) / m_qps * 100
        gain_list.append(gain)

    all_data[ratio] = {
        'gain':    gain_list,
        'r_avg':   r_avg_list,
        'r_p99':   r_p99_list,
        'w_avg':   w_avg_list,
        'w_p99':   w_p99_list,
        'm_qps':   m_qps,
        'has_read':  any(v > 0 for v in r_avg_list),
        'has_write': any(v > 0 for v in w_avg_list),
    }

xs = list(range(len(X_LABELS)))
read_ratios  = [r for r in all_data if all_data[r]['has_read']]
write_ratios = [r for r in all_data if all_data[r]['has_write']]

# ================================================================
# graph_overview.png  -- 2 rows x 3 cols
# ================================================================

fig, axes = plt.subplots(2, 3, figsize=(21, 10))
fig.suptitle(
    'PAUSE effect on memcached  [futex spinlock, -r 1, -t 32, mutilate -T 4 -c 4]\n'
    'Baseline: master branch (no spinlock)',
    fontsize=13, fontweight='bold')

def _plot_lat_panel(ax, ratios, key, ylabel, title):
    for ratio, color in zip(ratios, [RATIO_COLORS[RATIOS.index(r)] for r in ratios]):
        ax.plot(xs, all_data[ratio][key], marker='o', markersize=5, linewidth=2,
                color=color, label=ratio)
    vline_master(ax)
    set_xticks(ax, X_LABELS)
    ax.set_xlabel('pause_count', fontsize=10)
    ax.set_ylabel(ylabel, fontsize=10)
    ax.set_title(title, fontsize=11, fontweight='bold')
    ax.legend(fontsize=7, loc='best')
    ax.grid(True, alpha=0.3)

# row 0
ax = axes[0][0]
for ratio, color in zip(all_data.keys(), RATIO_COLORS):
    ax.plot(xs, all_data[ratio]['gain'], marker='o', markersize=5, linewidth=2,
            color=color, label=ratio)
ax.axhline(0, color='black', linestyle='--', linewidth=1.2, alpha=0.6)
vline_master(ax)
set_xticks(ax, X_LABELS)
ax.set_xlabel('pause_count', fontsize=10)
ax.set_ylabel('Throughput gain vs master (%)', fontsize=10)
ax.set_title('Throughput gain%', fontsize=11, fontweight='bold')
ax.legend(fontsize=7, loc='best')
ax.grid(True, alpha=0.3)

_plot_lat_panel(axes[0][1], read_ratios,  'r_avg', 'Read avg latency (µs)',  'Read avg latency')
_plot_lat_panel(axes[0][2], write_ratios, 'w_avg', 'Write avg latency (µs)', 'Write avg latency')

# row 1
axes[1][0].set_visible(False)
_plot_lat_panel(axes[1][1], read_ratios,  'r_p99', 'Read p99 latency (µs)',  'Read p99 latency')
_plot_lat_panel(axes[1][2], write_ratios, 'w_p99', 'Write p99 latency (µs)', 'Write p99 latency')

plt.tight_layout()
out = os.path.join(BASE_DIR, 'graph_overview.png')
fig.savefig(out, dpi=150, bbox_inches='tight')
plt.close(fig)
print(f'saved: {out}')

# ================================================================
# per_ratio/graph_{ratio}.png
# ================================================================

per_ratio_dir = os.path.join(BASE_DIR, 'per_ratio')
os.makedirs(per_ratio_dir, exist_ok=True)

for ratio, color in zip(all_data.keys(), RATIO_COLORS):
    d = all_data[ratio]
    has_lat = d['has_read'] or d['has_write']
    ncols = 3 if has_lat else 1
    fig, axes = plt.subplots(1, ncols, figsize=(7 * ncols, 5))
    if ncols == 1:
        axes = [axes]

    fig.suptitle(
        f'{ratio}  [master={d["m_qps"]/1000:.1f}k QPS]\n'
        'futex spinlock / -r 1 / -t 32 / mutilate -T 4 -c 4',
        fontsize=12, fontweight='bold')

    # panel 0: throughput gain%
    ax = axes[0]
    ax.plot(xs, d['gain'], marker='o', markersize=6, linewidth=2, color=color)
    ax.axhline(0, color='black', linestyle='--', linewidth=1.2, alpha=0.6,
               label=f'master ({d["m_qps"]/1000:.1f}k QPS)')
    vline_master(ax)
    for xi, g in zip(xs, d['gain']):
        ax.annotate(f'{g:+.1f}%', (xi, g),
                    textcoords='offset points', xytext=(0, 8 if g >= 0 else -14),
                    ha='center', fontsize=8)
    set_xticks(ax, X_LABELS)
    ax.set_xlabel('pause_count', fontsize=10)
    ax.set_ylabel('Throughput gain vs master (%)', fontsize=10)
    ax.set_title('Throughput gain%', fontsize=11, fontweight='bold')
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)

    if has_lat:
        # panel 1: avg latency (read + write)
        ax2 = axes[1]
        if d['has_read']:
            ax2.plot(xs, d['r_avg'], marker='o', markersize=6, linewidth=2,
                     color=color, label='read avg')
        if d['has_write']:
            ax2.plot(xs, d['w_avg'], marker='s', markersize=6, linewidth=2,
                     color=color, linestyle='--', label='write avg')
        vline_master(ax2)
        set_xticks(ax2, X_LABELS)
        ax2.set_xlabel('pause_count', fontsize=10)
        ax2.set_ylabel('Avg latency (µs)', fontsize=10)
        ax2.set_title('Avg latency', fontsize=11, fontweight='bold')
        ax2.legend(fontsize=9)
        ax2.grid(True, alpha=0.3)

        # panel 2: p99 latency (read + write)
        ax3 = axes[2]
        if d['has_read']:
            ax3.plot(xs, d['r_p99'], marker='o', markersize=6, linewidth=2,
                     color=color, label='read p99')
        if d['has_write']:
            ax3.plot(xs, d['w_p99'], marker='s', markersize=6, linewidth=2,
                     color=color, linestyle='--', label='write p99')
        vline_master(ax3)
        set_xticks(ax3, X_LABELS)
        ax3.set_xlabel('pause_count', fontsize=10)
        ax3.set_ylabel('p99 latency (µs)', fontsize=10)
        ax3.set_title('p99 latency', fontsize=11, fontweight='bold')
        ax3.legend(fontsize=9)
        ax3.grid(True, alpha=0.3)

    plt.tight_layout()
    out = os.path.join(per_ratio_dir, f'graph_{ratio}.png')
    fig.savefig(out, dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f'saved: {out}')

print('done.')
