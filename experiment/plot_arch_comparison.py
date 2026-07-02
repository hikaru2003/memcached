#!/usr/bin/env python3
# Usage:
#   cd ~/Application/memcached
#   python3 experiment/plot_arch_comparison.py
#
# Description:
#   各アーキテクチャの mysql-like-utdelay sweep 結果を比較グラフとして出力する。
#   対象ブランチ: experiment/mysql-like-utdelay
#   実装: [trylock → PAUSE×N] × SPIN_ROUNDS → mutex_lock
#   raw.csv からエラーバー・レイテンシ統計を計算する。
#
# Output:
#   experiment/results/utdelay_arch_qps.png        : 生QPS ± 1σ
#   experiment/results/utdelay_arch_normalized.png : master比正規化QPS ± 1σ
#   experiment/results/utdelay_arch_r_avg.png      : read avg latency ± 1σ
#   experiment/results/utdelay_arch_r_p99.png      : read p99 latency ± 1σ
#
# Prerequisites:
#   pip install matplotlib numpy
#   experiment/results/{arch}/utdelay_sweep_*/raw.csv が存在すること
#   （pause-spinlock ブランチのグラフは plot_pause_spinlock.py を使うこと）

import os
import re
import glob
import csv
import math
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

RESULTS_BASE = "experiment/results"

ARCH_INFO = {
    "broadwell":     ("Broadwell (xl170, PAUSE~12cyc)",           "tab:blue"),
    "emeraldrapids": ("Emerald Rapids (c6620, PAUSE~37cyc)",      "tab:green"),
    "icelake":       ("Ice Lake (sm110, PAUSE~39cyc)",             "tab:orange"),
    "ivybridge":     ("Ivy Bridge (c8220, PAUSE~15cyc)",          "tab:red"),
    "skylake":       ("Skylake c220g5 (PAUSE~142cyc)",            "tab:purple"),
    "skylake_ann":   ("Skylake ann (Xeon Silver 4114, PAUSE~142cyc)", "tab:pink"),
}

# annサーバの結果（arch サブディレクトリ構造外のため個別指定）
EXTRA_DIRS = {
    "skylake_ann": "experiment/results/utdelay_sweep_20260619_001650/raw.csv",
}


def std(vals):
    if len(vals) < 2:
        return 0.0
    m = sum(vals) / len(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / (len(vals) - 1))


def parse_raw_csv(path):
    """raw.csv をパースして label -> {qps, r_avg, r_p99, w_avg, w_p99} のリスト辞書を返す"""
    data = {}
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            label = row["label"]
            if label not in data:
                data[label] = {"qps": [], "r_avg": [], "r_p99": [], "w_avg": [], "w_p99": []}
            try:
                data[label]["qps"].append(float(row["QPS"]))
                data[label]["r_avg"].append(float(row["r_avg_us"]))
                data[label]["r_p99"].append(float(row["r_p99_us"]))
                data[label]["w_avg"].append(float(row["w_avg_us"]))
                data[label]["w_p99"].append(float(row["w_p99_us"]))
            except (ValueError, KeyError):
                pass
    return data


def aggregate(raw):
    """raw -> {label: {ppr, mean_qps, sd_qps, mean_r_avg, sd_r_avg, mean_r_p99, sd_r_p99, ...}}"""
    result = {}
    for label, vals in raw.items():
        if label == "master":
            ppr = -1
        else:
            m = re.match(r'N(\d+)', label)
            ppr = int(m.group(1)) if m else None
            if ppr is None:
                continue
        result[label] = {
            "ppr": ppr,
            "mean_qps":   np.mean(vals["qps"]),
            "sd_qps":     np.std(vals["qps"], ddof=1) if len(vals["qps"]) > 1 else 0,
            "mean_r_avg": np.mean(vals["r_avg"]),
            "sd_r_avg":   np.std(vals["r_avg"], ddof=1) if len(vals["r_avg"]) > 1 else 0,
            "mean_r_p99": np.mean(vals["r_p99"]),
            "sd_r_p99":   np.std(vals["r_p99"], ddof=1) if len(vals["r_p99"]) > 1 else 0,
            "mean_w_p99": np.mean(vals["w_p99"]),
            "sd_w_p99":   np.std(vals["w_p99"], ddof=1) if len(vals["w_p99"]) > 1 else 0,
            "n": len(vals["qps"]),
        }
    return result


def find_latest_csv(arch_dir):
    files = sorted(glob.glob(os.path.join(arch_dir, "utdelay_sweep_*", "raw.csv")))
    if not files:
        files = sorted(glob.glob(os.path.join(arch_dir, "*/raw.csv")))
    return files[-1] if files else None


def load_all():
    datasets = {}
    for arch_dir in sorted(glob.glob(os.path.join(RESULTS_BASE, "*"))):
        arch = os.path.basename(arch_dir)
        if arch not in ARCH_INFO or arch in EXTRA_DIRS:
            continue
        csv_path = find_latest_csv(arch_dir)
        if not csv_path:
            continue
        raw = parse_raw_csv(csv_path)
        data = aggregate(raw)
        if data:
            datasets[arch] = data
            print(f"  loaded {arch}: {csv_path} ({len(data)} labels)")

    for arch, csv_path in EXTRA_DIRS.items():
        if not os.path.exists(csv_path):
            print(f"  [WARN] {arch}: {csv_path} not found, skipping")
            continue
        raw = parse_raw_csv(csv_path)
        data = aggregate(raw)
        if data:
            datasets[arch] = data
            print(f"  loaded {arch}: {csv_path} ({len(data)} labels)")

    return datasets


def extract_curve(data, key_mean, key_sd, exclude_master=True):
    """(xs, means, sds) を N 昇順で返す。master は xs=-1 として含めるか除外する。"""
    points = []
    for label, v in data.items():
        if exclude_master and label == "master":
            continue
        points.append((v["ppr"], v[key_mean], v[key_sd]))
    points.sort()
    if not points:
        return [], [], []
    xs, means, sds = zip(*points)
    return list(xs), list(means), list(sds)


COMMON_TITLE_SUFFIX = "spinlock: [trylock→PAUSE×N]×30→mutex_lock / mc=4t / mut -T4 -c1 -d32 -r1 -u0.5 / n=20"


def plot_qps(datasets, out_path):
    fig, ax = plt.subplots(figsize=(11, 6))
    for arch, data in datasets.items():
        disp, color = ARCH_INFO.get(arch, (arch, None))
        xs, ys, es = extract_curve(data, "mean_qps", "sd_qps")
        ys_k = [y / 1000 for y in ys]
        es_k = [e / 1000 for e in es]
        ax.errorbar(xs, ys_k, yerr=es_k, label=disp, color=color,
                    marker='o', markersize=4, linewidth=1.5,
                    capsize=3, elinewidth=1.0)
        if "master" in data:
            mq = data["master"]["mean_qps"] / 1000
            ms = data["master"]["sd_qps"] / 1000
            ax.axhline(mq, color=color, linestyle='--', linewidth=0.8, alpha=0.45)

    ax.set_xlabel("pause_per_round (N)", fontsize=12)
    ax.set_ylabel("Mean QPS (kQPS)  ±1σ", fontsize=12)
    ax.set_title(f"QPS vs pause_per_round (error bars = ±1σ)\n{COMMON_TITLE_SUFFIX}", fontsize=10)
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    ax.set_xlim(left=-1)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  saved: {out_path}")


def plot_normalized(datasets, out_path):
    fig, ax = plt.subplots(figsize=(11, 6))
    for arch, data in datasets.items():
        disp, color = ARCH_INFO.get(arch, (arch, None))
        if "master" not in data:
            continue
        master_qps = data["master"]["mean_qps"]
        master_sd  = data["master"]["sd_qps"]

        xs, ys, es = extract_curve(data, "mean_qps", "sd_qps")
        ys_n = [y / master_qps for y in ys]
        # 誤差伝播: σ(y/c) = σ_y/c (cを定数とみなす)
        es_n = [e / master_qps for e in es]

        ax.errorbar(xs, ys_n, yerr=es_n, label=disp, color=color,
                    marker='o', markersize=4, linewidth=1.5,
                    capsize=3, elinewidth=1.0)

    ax.axhline(1.0, color='black', linestyle='--', linewidth=1.2,
               alpha=0.7, label="master baseline (=1.0)")
    ax.set_xlabel("pause_per_round (N)", fontsize=12)
    ax.set_ylabel("QPS / master_QPS  ±1σ", fontsize=12)
    ax.set_title(f"Normalized QPS gain over master (error bars = ±1σ)\n{COMMON_TITLE_SUFFIX}", fontsize=10)
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    ax.set_xlim(left=-1)
    ax.yaxis.set_major_formatter(ticker.FormatStrFormatter('%.2f'))
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  saved: {out_path}")


def plot_latency(datasets, key_mean, key_sd, ylabel, title_prefix, out_path):
    fig, ax = plt.subplots(figsize=(11, 6))
    for arch, data in datasets.items():
        disp, color = ARCH_INFO.get(arch, (arch, None))
        xs, ys, es = extract_curve(data, key_mean, key_sd)
        ax.errorbar(xs, ys, yerr=es, label=disp, color=color,
                    marker='o', markersize=4, linewidth=1.5,
                    capsize=3, elinewidth=1.0)
        if "master" in data:
            ml = data["master"][key_mean]
            ax.axhline(ml, color=color, linestyle='--', linewidth=0.8, alpha=0.45)

    ax.set_xlabel("pause_per_round (N)", fontsize=12)
    ax.set_ylabel(f"{ylabel}  ±1σ", fontsize=12)
    ax.set_title(f"{title_prefix} (error bars = ±1σ)\n{COMMON_TITLE_SUFFIX}", fontsize=10)
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    ax.set_xlim(left=-1)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  saved: {out_path}")


def print_analysis(datasets):
    print("\n" + "=" * 70)
    print("=== 分析レポート ===")
    print("=" * 70)

    for arch, data in sorted(datasets.items()):
        disp, _ = ARCH_INFO.get(arch, (arch, ""))
        master = data.get("master")
        if not master:
            continue
        mq = master["mean_qps"]

        points = [(v["ppr"], v["mean_qps"], v["sd_qps"])
                  for k, v in data.items() if k != "master"]
        points.sort()
        ns   = [p[0] for p in points]
        qps  = [p[1] for p in points]
        sds  = [p[2] for p in points]

        peak_idx = int(np.argmax(qps))
        peak_n   = ns[peak_idx]
        peak_q   = qps[peak_idx]
        peak_sd  = sds[peak_idx]
        gain     = peak_q / mq

        # N=0 vs master: スピン自体の効果
        n0_q  = qps[ns.index(0)] if 0 in ns else None
        n0_gain = n0_q / mq if n0_q else None

        # 低N域(0-10)の変動係数（ノイズ指標）
        low_n_qps = [qps[i] for i, n in enumerate(ns) if 0 <= n <= 10]
        low_n_cv  = np.std(low_n_qps, ddof=1) / np.mean(low_n_qps) * 100 if low_n_qps else 0

        print(f"\n--- {disp} ---")
        print(f"  master QPS       : {mq/1e3:.1f} kQPS")
        print(f"  N=0  QPS         : {n0_q/1e3:.1f} kQPS  (gain vs master: {n0_gain:.3f}x)" if n0_q else "  N=0: N/A")
        print(f"  peak QPS         : {peak_q/1e3:.1f} ± {peak_sd/1e3:.1f} kQPS  @ N={peak_n}  (gain: {gain:.3f}x)")
        print(f"  N=200 QPS        : {qps[-1]/1e3:.1f} kQPS  ({qps[-1]/mq:.3f}x master)")
        print(f"  低N域(N=0-10)変動: CV={low_n_cv:.1f}%  {'← 傾向不明瞭' if low_n_cv > 2 else '← 安定'}")

        # 傾向判定
        high_n_qps = [qps[i] for i, n in enumerate(ns) if n >= 20]
        if high_n_qps and high_n_qps[-1] < high_n_qps[0] * 0.95:
            trend_high = "N≥20 以降は単調減少傾向"
        elif high_n_qps and high_n_qps[-1] > high_n_qps[0] * 0.95:
            trend_high = "N≥20 以降も高水準を維持（明確な減少なし）"
        else:
            trend_high = "N≥20 以降の傾向不明確"
        print(f"  高N域傾向        : {trend_high}")

    print("\n=== 総括 ===")
    print("""
Skylake (PAUSE~142cyc):
  スピンロック導入でmaster比+50%程度のQPS改善。
  N=4-10付近でピーク後、N増加とともにQPSが単調減少する明確な傾向が確認できる。
  PAUSE1回のコストが142cycと重いため、Nを増やすほど競合スレッドのスループットを
  過度に抑制し逆効果となると解釈できる。ただしN=0(スピンのみ)でもmaster比+30%の
  改善があり、PAUSEよりトライロック自体の効果が大きい可能性がある。

Broadwell (PAUSE~12cyc):
  全体的なQPS改善はあるものの、低N域(N=0-10)でQPSが増減を繰り返し傾向が不明瞭。
  エラーバーが重なる点が多く、この領域では統計的有意な差があるとは言いにくい。
  PAUSE~12cycはコストが小さいため、1回あたりの効果も小さく、個々の計測値の
  ばらつき(CV~0.3%)より大きな信号を出すには十分でない可能性がある。
  N=80前後でピークに見えるが、N=50-100の広い範囲でほぼ同等のQPSが出ており、
  「最適N」を一点に絞るのは困難。

Emerald Rapids (PAUSE~37cyc):
  N=0からN=30にかけて段階的にQPSが上昇し、N=30付近でピークを迎える。
  その後N=50-200でも高水準を維持しており、Skylakeのような急激な劣化はない。
  傾向はBroadwellよりは読み取りやすいが、低N域でも一部の揺れがあり
  「明確に単調増加」とまでは言えない。PAUSE~37cycはSkylakeほど重くないため
  Nを多くしても許容できると考えられる一方、最適点の同定には追加実験が必要。

共通の課題:
  - N=0(PAUSE=0のスピン)がmaster比で既に大きく改善している点を無視できない。
    PAUSEの有無より「トライロックループ自体」の効果が主因である可能性がある。
  - 低N域の揺れはサーバ上の他プロセス・スケジューラノイズの影響も考えられ、
    現行のRUNS=20では統計的に不十分な場合がある。
  - レイテンシは次グラフ参照。QPS向上と引き換えにレイテンシが改善/悪化するか
    確認が必要。
""")


if __name__ == "__main__":
    print("Loading results...")
    datasets = load_all()

    if not datasets:
        print("[ERROR] No result data found.")
        exit(1)

    print_analysis(datasets)

    print("\nGenerating plots...")
    plot_qps(datasets,
             os.path.join(RESULTS_BASE, "utdelay_arch_qps.png"))
    plot_normalized(datasets,
                    os.path.join(RESULTS_BASE, "utdelay_arch_normalized.png"))
    plot_latency(datasets, "mean_r_avg", "sd_r_avg",
                 "Read avg latency (us)",
                 "Read avg latency vs pause_per_round",
                 os.path.join(RESULTS_BASE, "utdelay_arch_r_avg.png"))
    plot_latency(datasets, "mean_r_p99", "sd_r_p99",
                 "Read p99 latency (us)",
                 "Read p99 latency vs pause_per_round",
                 os.path.join(RESULTS_BASE, "utdelay_arch_r_p99.png"))

    print("\nDone.")
