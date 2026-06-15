"""
Usage:
    cd experiment/results
    python3 update_summaries.py

Description:
    既存の summary.md ファイルに write latency (write_avg_us / write_p99_us) 列を追加する。
    ログファイルから read/write latency を runs 分平均して再計算する。

    対象ディレクトリ:
      ratio_sweep_*/get*/summary.md     -- ログ: run_P{pc}_{run}.log
      pause_sweep_sched_yield/summary.md -- ログ: run_{pc}_{run}.log
      utdelay_sweep/summary.md          -- ログ: run_N{n}_{run}.log

    ycsb_var_* はすでに update_avg_us を持つためスキップ。

Output:
    各 summary.md をその場で上書き更新する。元のファイルは .bak として保存。

Prerequisites:
    Python 3.6+
"""

import os
import re
import glob
import shutil

BASE = os.path.dirname(os.path.abspath(__file__))


def parse_latency_from_logs(logs, metric):
    """logs リストから metric ('read'/'update') の avg と p99 を runs 分平均して返す。"""
    avgs, p99s = [], []
    for log in sorted(logs):
        with open(log) as f:
            for line in f:
                if re.match(rf'^{metric}\s', line):
                    parts = line.split()
                    if len(parts) >= 9:
                        avgs.append(float(parts[1]))
                        p99s.append(float(parts[8]))
                    break
    if not avgs:
        return 0.0, 0.0
    return sum(avgs) / len(avgs), sum(p99s) / len(p99s)


def already_has_write(summary_path):
    with open(summary_path) as f:
        for line in f:
            if 'write_avg_us' in line:
                return True
    return False


def update_ratio_sweep_subdir(summary_path, log_dir, log_pattern_fn):
    """
    ratio_sweep 形式の summary.md を更新する。
    log_pattern_fn(pc) -> glob pattern string
    """
    if already_has_write(summary_path):
        print(f'  [skip] already updated: {summary_path}')
        return

    with open(summary_path) as f:
        lines = f.readlines()

    new_lines = []
    for line in lines:
        # header line (pause_count or pause_per_round)
        if re.match(r'\| pause_\w+ \|', line) and '| mean_QPS |' in line:
            line = line.rstrip()
            if '| n |' in line:
                line = line.replace('| n |', '| write_avg_us | write_p99_us | n |')
            new_lines.append(line + '\n')
            continue

        # separator line: append two more ---| cells to the existing row
        if re.match(r'\|---\|', line):
            line = line.rstrip() + '---|---|'
            new_lines.append(line + '\n')
            continue

        # data row: | pc | mean_QPS | ... | read_avg_us | read_p99_us | n |
        m = re.match(r'\|\s*(\d+)\s*\|', line)
        if m:
            pc = int(m.group(1))
            logs = glob.glob(os.path.join(log_dir, log_pattern_fn(pc)))
            w_avg, w_p99 = parse_latency_from_logs(logs, 'update')
            line = line.rstrip()
            # insert before last " | n |"
            line = re.sub(r'\|\s*(\d+)\s*\|\s*$',
                          f'| {w_avg:.1f} | {w_p99:.1f} | \\1 |', line)
            new_lines.append(line + '\n')
            continue

        new_lines.append(line)

    shutil.copy2(summary_path, summary_path + '.bak')
    with open(summary_path, 'w') as f:
        f.writelines(new_lines)
    print(f'  updated: {summary_path}')


def update_flat_summary(summary_path, log_dir, log_pattern_fn):
    """
    pause_sweep / utdelay 形式 (flat directory, same as ratio_sweep subdir format) を更新する。
    """
    update_ratio_sweep_subdir(summary_path, log_dir, log_pattern_fn)


# ----------------------------------------------------------------
# ratio_sweep_* / get*_set* / summary.md
# ----------------------------------------------------------------

for exp_dir in sorted(glob.glob(os.path.join(BASE, 'ratio_sweep_*'))):
    print(f'\n[ratio_sweep] {os.path.basename(exp_dir)}')
    for ratio_dir in sorted(glob.glob(os.path.join(exp_dir, 'get*_set*'))):
        summary = os.path.join(ratio_dir, 'summary.md')
        if not os.path.exists(summary):
            continue
        update_ratio_sweep_subdir(
            summary,
            log_dir=ratio_dir,
            log_pattern_fn=lambda pc: f'run_P{pc}_*.log',
        )

# ----------------------------------------------------------------
# pause_sweep_sched_yield / summary.md
# ----------------------------------------------------------------

print(f'\n[pause_sweep_sched_yield]')
ps_dir = os.path.join(BASE, 'pause_sweep_sched_yield')
ps_summary = os.path.join(ps_dir, 'summary.md')
if os.path.exists(ps_summary):
    update_flat_summary(
        ps_summary,
        log_dir=ps_dir,
        log_pattern_fn=lambda pc: f'run_{pc}_*.log',
    )

# ----------------------------------------------------------------
# utdelay_sweep / summary.md
# ----------------------------------------------------------------

print(f'\n[utdelay_sweep]')
ut_dir = os.path.join(BASE, 'utdelay_sweep')
ut_summary = os.path.join(ut_dir, 'summary.md')
if os.path.exists(ut_summary):
    update_flat_summary(
        ut_summary,
        log_dir=ut_dir,
        log_pattern_fn=lambda pc: f'run_N{pc}_*.log',
    )

print('\ndone.')
