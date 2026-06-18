"""
Usage:
    cd experiment/results/ycsb_var_pause_sweep_YYYYMMDD_HHMMSS
    python3 ../ycsb_var_pause_sweep/plot_graphs.py
  or:
    python3 experiment/results/ycsb_var_pause_sweep/plot_graphs.py \
        --result-dir experiment/results/ycsb_var_pause_sweep_YYYYMMDD_HHMMSS

Description:
    ycsb_var_pause_sweep の summary.md / master_baseline/summary.md から
    グラフを生成する。

Output:
    {result_dir}/graph_overview.png  -- 3パネル (gain%, read avg, update avg latency)

Parameters:
    --result-dir : 結果ディレクトリのパス (default: スクリプトの親ディレクトリ)

Prerequisites:
    pip install matplotlib
    summary.md と master_baseline/summary.md が存在すること
"""

import os
import re
import sys
import argparse
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('--result-dir', default=None,
                   help='Path to result directory (default: parent of this script)')
    return p.parse_args()


def find_latest_result_dir(base):
    """experiment/results/ から最新の ycsb_var_pause_sweep_* を探す"""
    parent = os.path.join(base, '..', 'results')
    parent = os.path.normpath(parent)
    if not os.path.isdir(parent):
        return None
    dirs = sorted(
        [d for d in os.listdir(parent) if d.startswith('ycsb_var_pause_sweep_')],
        reverse=True
    )
    return os.path.join(parent, dirs[0]) if dirs else None


def parse_master_baseline(path):
    """
    master_baseline/summary.md:
    | master_baseline | mean_OPS | ... | read_avg_us | read_p99_us | update_avg_us | update_p99_us | n |
    """
    with open(path) as f:
        for line in f:
            m = re.match(
                r'\|\s*master_baseline\s*\|'
                r'\s*([\d.]+)\s*\|'           # mean_OPS
                r'\s*[\d.]+\s*\|'             # median_OPS
                r'\s*[\d.]+\s*\|'             # stddev_OPS
                r'\s*[\d.]+\s*\|'             # cv_pct
                r'\s*([\d.]+)\s*\|'           # read_avg_us
                r'\s*[\d.]+\s*\|'             # read_p99_us
                r'\s*([\d.]+)\s*\|'           # update_avg_us
                r'\s*[\d.]+\s*\|',            # update_p99_us
                line)
            if m:
                return float(m.group(1)), float(m.group(2)), float(m.group(3))
    return None, None, None


def parse_sweep_summary(path):
    """
    summary.md:
    | pause_count | mean_OPS | ... | read_avg_us | read_p99_us | update_avg_us | update_p99_us | gain_vs_master% | n |
    """
    rows = []
    with open(path) as f:
        for line in f:
            m = re.match(
                r'\|\s*(\d+)\s*\|'            # pause_count
                r'\s*([\d.]+)\s*\|'           # mean_OPS
                r'\s*[\d.]+\s*\|'             # median_OPS
                r'\s*[\d.]+\s*\|'             # stddev_OPS
                r'\s*[\d.]+\s*\|'             # cv_pct
                r'\s*([\d.]+)\s*\|'           # read_avg_us
                r'\s*[\d.]+\s*\|'             # read_p99_us
                r'\s*([\d.]+)\s*\|'           # update_avg_us
                r'\s*[\d.]+\s*\|'             # update_p99_us
                r'\s*([+\-]?[\d.]+)%\s*\|',  # gain_vs_master%
                line)
            if m:
                rows.append({
                    'pause':  int(m.group(1)),
                    'ops':    float(m.group(2)),
                    'r_avg':  float(m.group(3)),
                    'w_avg':  float(m.group(4)),
                    'gain':   float(m.group(5)),
                })
    return rows


def set_xticks(ax, labels):
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, fontsize=9)


def vline_master(ax):
    ax.axvline(0.5, color='gray', linestyle=':', linewidth=1.0, alpha=0.5)


def main():
    args = parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))

    if args.result_dir:
        result_dir = os.path.abspath(args.result_dir)
    else:
        result_dir = find_latest_result_dir(script_dir)
        if result_dir is None:
            # スクリプトが結果ディレクトリ内に置かれている場合
            result_dir = script_dir

    summary_path  = os.path.join(result_dir, 'summary.md')
    baseline_path = os.path.join(result_dir, 'master_baseline', 'summary.md')

    if not os.path.exists(summary_path):
        print(f'ERROR: {summary_path} not found')
        sys.exit(1)
    if not os.path.exists(baseline_path):
        print(f'ERROR: {baseline_path} not found')
        sys.exit(1)

    m_ops, m_r_avg, m_w_avg = parse_master_baseline(baseline_path)
    if m_ops is None:
        print('ERROR: could not parse master baseline')
        sys.exit(1)

    rows = parse_sweep_summary(summary_path)
    if not rows:
        print('ERROR: no rows parsed from summary.md')
        sys.exit(1)

    pauses = [r['pause'] for r in rows]
    gains  = [0.0] + [r['gain']  for r in rows]
    r_avgs = [m_r_avg] + [r['r_avg'] for r in rows]
    w_avgs = [m_w_avg] + [r['w_avg'] for r in rows]
    labels = ['master'] + [str(p) for p in pauses]
    xs     = list(range(len(labels)))

    COLOR = '#1f77b4'

    fig, axes = plt.subplots(1, 3, figsize=(21, 5))
    fig.suptitle(
        'PAUSE spinlock effect — YCSB VAR workload  [Zipf s=1.107, 82% UPDATE, 100k keys, 500B, -t 32, ycsb_threads=16]\n'
        f'Baseline: master branch  ({m_ops/1000:.1f}k OPS)',
        fontsize=13, fontweight='bold')

    # panel 1: gain%
    ax = axes[0]
    ax.plot(xs, gains, marker='o', markersize=5, linewidth=2, color=COLOR)
    ax.axhline(0, color='black', linestyle='--', linewidth=1.2, alpha=0.6,
               label=f'master ({m_ops/1000:.1f}k OPS)')
    vline_master(ax)
    for xi, g in zip(xs, gains):
        ax.annotate(f'{g:+.1f}%', (xi, g),
                    textcoords='offset points', xytext=(0, 8 if g >= 0 else -14),
                    ha='center', fontsize=7.5)
    set_xticks(ax, labels)
    ax.set_xlabel('pause_count', fontsize=10)
    ax.set_ylabel('Throughput gain vs master (%)', fontsize=10)
    ax.set_title('Throughput gain%', fontsize=11, fontweight='bold')
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)

    # panel 2: read avg latency
    ax = axes[1]
    ax.plot(xs, r_avgs, marker='o', markersize=5, linewidth=2, color=COLOR, label='read avg')
    vline_master(ax)
    set_xticks(ax, labels)
    ax.set_xlabel('pause_count', fontsize=10)
    ax.set_ylabel('Read avg latency (µs)', fontsize=10)
    ax.set_title('Read avg latency', fontsize=11, fontweight='bold')
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    # panel 3: update avg latency
    ax = axes[2]
    ax.plot(xs, w_avgs, marker='s', markersize=5, linewidth=2, color=COLOR,
            linestyle='--', label='update avg')
    vline_master(ax)
    set_xticks(ax, labels)
    ax.set_xlabel('pause_count', fontsize=10)
    ax.set_ylabel('Update avg latency (µs)', fontsize=10)
    ax.set_title('Update avg latency', fontsize=11, fontweight='bold')
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    out = os.path.join(result_dir, 'graph_overview.png')
    fig.savefig(out, dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f'saved: {out}')
    print('done.')


if __name__ == '__main__':
    main()
