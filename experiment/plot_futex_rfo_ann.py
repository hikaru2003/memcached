#!/usr/bin/env python3
"""
Usage:
    python3 experiment/plot_futex_rfo_ann.py

Description:
    Skylake ann 単独の futex 落ち回数と RFO の N 依存を可視化する。
    - futex_ann.pdf: futex/req vs N (log scale, master baseline も表示)
    - rfo_ann.pdf: RFO/req vs N (linear scale)

Parameters:
    hard-coded paths:
      futex csv    - experiment/results/archive/20260910/skylake_ann/futex_20260728_144252/summary.csv
      cache_miss csv - experiment/results/archive/20260910/skylake_ann/cache_miss_20260708_183431/summary.csv

Output:
    experiment/results/plots/v3/futex_ann.pdf
    experiment/results/plots/v3/rfo_ann.pdf
"""
import csv
import os
import re
from statistics import mean

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter


FUTEX_CSV = "experiment/results/archive/20260910/skylake_ann/futex_20260728_144252/summary.csv"
RFO_CSV = "experiment/results/archive/20260910/skylake_ann/cache_miss_20260708_183431/summary.csv"
OUTDIR = "experiment/results/plots/v3"


def load_futex(path):
    """returns (ns, futex_per_req_mean, master_futex_per_req)"""
    d = {}
    with open(path) as f:
        r = csv.DictReader(f)
        for row in r:
            lab = row["label"]
            try:
                fpr = float(row["futex_per_req"])
            except (KeyError, ValueError):
                continue
            d.setdefault(lab, []).append(fpr)
    ns, means = [], []
    for lab, vals in d.items():
        if lab == "master":
            continue
        m = re.match(r"N(\d+)", lab)
        if m:
            ns.append(int(m.group(1)))
            means.append(mean(vals))
    order = sorted(range(len(ns)), key=lambda i: ns[i])
    ns = [ns[i] for i in order]
    means = [means[i] for i in order]
    master = mean(d["master"]) if "master" in d else None
    return ns, means, master


def load_rfo(path):
    """returns (ns, rfo_per_req_mean)"""
    d = {}
    with open(path) as f:
        r = csv.DictReader(f)
        for row in r:
            lab = row["label"]
            try:
                qps = float(row["QPS"])
                rfo = float(row["demand_rfo"])
            except (KeyError, ValueError):
                continue
            rfo_per_req = rfo / (qps * 30)  # duration=30s
            d.setdefault(lab, []).append(rfo_per_req)
    ns, means = [], []
    for lab, vals in d.items():
        if lab == "master":
            continue
        m = re.match(r"N(\d+)", lab)
        if m:
            ns.append(int(m.group(1)))
            means.append(mean(vals))
    order = sorted(range(len(ns)), key=lambda i: ns[i])
    ns = [ns[i] for i in order]
    means = [means[i] for i in order]
    return ns, means


def plot_futex(ns, futex, master, out_pdf):
    fig, ax = plt.subplots(figsize=(9, 5.5))
    ax.plot(ns, futex, marker="o", ms=6, lw=2, color="tab:green", label="futex/req (spin+PAUSE)")
    if master is not None:
        ax.axhline(master, color="tab:red", ls="--", lw=1.8,
                   label=f"master (no spin): {master:.2f}/req")
    ax.set_xlabel("PAUSE per round (N)", fontsize=13)
    ax.set_ylabel("futex syscalls / request", fontsize=13)
    ax.set_title("futex syscall rate vs N  (skylake ann)", fontsize=13)
    ax.set_yscale("log")
    ax.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"{x:g}"))
    ax.yaxis.set_minor_formatter(FuncFormatter(lambda x, _: ""))
    ax.set_yticks([0.001, 0.01, 0.1, 1.0, 2.0])
    ax.grid(True, which="both", alpha=0.3)
    ax.tick_params(axis="both", labelsize=12)
    ax.legend(fontsize=12, loc="upper right")
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def plot_rfo(ns, rfo, out_pdf):
    fig, ax = plt.subplots(figsize=(9, 5.5))
    ax.plot(ns, rfo, marker="o", ms=6, lw=2, color="tab:green", label="demand_rfo / request")
    peak_i = max(range(len(rfo)), key=lambda i: rfo[i])
    ax.axvline(ns[peak_i], color="gray", ls="--", alpha=0.5,
               label=f"RFO peak: N={ns[peak_i]} ({rfo[peak_i]:.1f})")
    ax.set_xlabel("PAUSE per round (N)", fontsize=13)
    ax.set_ylabel("RFO (offcore demand_rfo) / request", fontsize=13)
    ax.set_title("RFO (bus contention) vs N  (skylake ann)", fontsize=13)
    ax.grid(True, alpha=0.3)
    ax.tick_params(axis="both", labelsize=12)
    ax.legend(fontsize=12, loc="upper right")
    fig.tight_layout()
    fig.savefig(out_pdf, bbox_inches="tight")
    plt.close(fig)
    print(f"[write] {out_pdf}")


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    ns, futex, master = load_futex(FUTEX_CSV)
    plot_futex(ns, futex, master, os.path.join(OUTDIR, "futex_ann.pdf"))
    ns_r, rfo = load_rfo(RFO_CSV)
    plot_rfo(ns_r, rfo, os.path.join(OUTDIR, "rfo_ann.pdf"))


if __name__ == "__main__":
    main()
