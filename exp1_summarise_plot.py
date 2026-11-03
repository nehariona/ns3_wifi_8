#!/usr/bin/env python3
"""
Summarise Experiment 1 raw CSVs, write tables and draw graphs.

Output layout (<OUT> = e.g. 3rd_nov_320mhz/exp1):

  <OUT>/<traffic>/analysis/exp1_summary_mean_ci.csv      mean, std, n, 95% CI (long format)
  <OUT>/<traffic>/analysis/exp1_paired_vs_0pct.csv       paired difference vs 0% adoption
  <OUT>/<traffic>/analysis/tables/exp1_<metric>_mean_table.csv      adoption % x AC, numbers
  <OUT>/<traffic>/analysis/tables/exp1_<metric>_mean_ci_table.csv   adoption % x AC, "mean ± ci"
  <OUT>/<traffic>/analysis/plots/<metric>.png            metric vs adoption (95% CI bars)
  <OUT>/<traffic>/analysis/plots/paired/<metric>.png     change vs 0% adoption
  <OUT>/summary/exp1_summary_ci_all_traffic.csv          all traffic types combined
  <OUT>/summary/exp1_paired_vs_0pct_all_traffic.csv
  <OUT>/summary/plots/<metric>_by_traffic.png            one panel per traffic type
  <OUT>/summary/plots/<metric>_paired_by_traffic.png

Usage:
  python3 exp1_summarise_plot.py 3rd_nov_320mhz/exp1
  python3 exp1_summarise_plot.py OUT --keys ac --metrics throughputMbps meanDelayMs
"""
import argparse
import glob
import os
import re
import sys

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

try:
    from scipy import stats

    def tcrit(n):
        return stats.t.ppf(0.975, np.maximum(np.asarray(n) - 1, 1))
except ImportError:
    def tcrit(n):
        return np.full(np.shape(n), 1.96)

# file name: L8_D1_exp1_25pct_run3.csv  ->  adoption 25, replicate 3
FNAME = re.compile(r"_exp1_(\d+)pct_run(\d+)\.csv$")

DEFAULT_KEYS = ["ac"]
DEFAULT_METRICS = [
    "throughputMbps", "payloadGoodputMbps", "pdr", "packetLossRate",
    "meanDelayMs", "p95DelayMs", "p99DelayMs", "p999DelayMs", "meanJitterMs",
    "macRetransmissions", "macDataAttempts", "retxRatio",
    "dsCtsTransmissions", "stage2RtsTransmissions",
]
# metrics that also get a readable adoption-by-AC table
TABLE_METRICS = ["meanDelayMs", "p95DelayMs", "p99DelayMs",
                 "throughputMbps", "pdr", "retxRatio"]


# ------------------------------------------------------------------ loading
def load(out):
    frames = []
    for f in sorted(glob.glob(os.path.join(out, "*", "raw", "*.csv"))):
        m = FNAME.search(f)
        if not m or os.path.getsize(f) == 0:
            continue
        try:
            d = pd.read_csv(f)
        except Exception as e:
            print(f"  skip {f}: {e}", file=sys.stderr)
            continue
        d["traffic"] = f.split(os.sep)[-3]
        d["adoptionPct"] = int(m.group(1))
        d["replicate"] = int(m.group(2))
        if {"macRetransmissions", "macDataAttempts"} <= set(d.columns):
            d["retxRatio"] = d["macRetransmissions"] / \
                d["macDataAttempts"].replace(0, np.nan)
        frames.append(d)
    if not frames:
        sys.exit(f"No raw CSVs found under {out}/*/raw/")
    return pd.concat(frames, ignore_index=True)


# ------------------------------------------------------------------ statistics
def to_long(df, keys, metrics):
    long = df.melt(id_vars=["traffic", "adoptionPct", "replicate", *keys],
                   value_vars=metrics, var_name="metric", value_name="value")
    # one value per replicate and group (averages duplicate rows, if any)
    return (long.groupby(["traffic", "adoptionPct", "replicate", *keys, "metric"],
                         dropna=False)["value"].mean().reset_index())


def summarise(long, keys):
    g = long.groupby(["traffic", "adoptionPct", *keys, "metric"],
                     dropna=False)["value"]
    s = g.agg(mean="mean", std="std", n="count").reset_index()
    s["ci95"] = tcrit(s["n"].values) * s["std"] / np.sqrt(s["n"].clip(lower=1))
    s.loc[s["n"] < 2, "ci95"] = np.nan
    return s


def paired_vs_baseline(long, keys):
    idx = ["traffic", "replicate", *keys, "metric"]
    base = long[long.adoptionPct == 0][idx + ["value"]] \
        .rename(columns={"value": "base"})
    if base.empty:
        return None
    m = long.merge(base, on=idx, how="inner")
    m["value"] = m["value"] - m["base"]   # same seed/run => same traffic realisation
    return summarise(m.drop(columns="base"), keys)


# ------------------------------------------------------------------ tables
def write_wide_tables(s, keys, outdir):
    """adoptionPct as rows, AC as columns; one file per key metric."""
    os.makedirs(outdir, exist_ok=True)
    s = s.copy()
    s["grp"] = s[keys].astype(str).apply(" / ".join, axis=1) if keys else "all"
    for metric in TABLE_METRICS:
        d = s[s.metric == metric].copy()
        if d.empty:
            continue
        d["cell"] = [f"{m:.3f} ± {0 if pd.isna(c) else c:.3f}"
                     for m, c in zip(d["mean"], d["ci95"])]
        d.pivot(index="adoptionPct", columns="grp", values="mean") \
            .to_csv(os.path.join(outdir, f"exp1_{metric}_mean_table.csv"))
        d.pivot(index="adoptionPct", columns="grp", values="cell") \
            .to_csv(os.path.join(outdir, f"exp1_{metric}_mean_ci_table.csv"))


# ------------------------------------------------------------------ plotting
def label(row, keys):
    return " / ".join(str(row[k]) for k in keys) if keys else "all"


def draw(ax, s, keys, ylabel, zero_line=False):
    if not keys:
        groups = [("all", s)]
    else:
        groups = [(label(r, keys), s[(s[keys] == r[keys]).all(axis=1)])
                  for _, r in s[keys].drop_duplicates().iterrows()]
    for name, d in groups:
        d = d.sort_values("adoptionPct")
        ax.errorbar(d.adoptionPct, d["mean"], yerr=d["ci95"].fillna(0),
                    marker="o", capsize=3, lw=1.5, label=name)
    if zero_line:
        ax.axhline(0, color="grey", lw=0.8, ls="--")
    ax.set_xlabel("% of VO STAs using P-EDCA")
    ax.set_ylabel(ylabel)
    ax.set_xticks(sorted(s.adoptionPct.unique()))
    ax.grid(alpha=0.3)
    if keys:
        ax.legend(fontsize=8, title=" / ".join(keys))


def plot_per_traffic(s, keys, outdir, tag="", zero_line=False):
    os.makedirs(outdir, exist_ok=True)
    for metric, d in s.groupby("metric"):
        fig, ax = plt.subplots(figsize=(6.5, 4.2))
        draw(ax, d, keys, ("Δ " if zero_line else "") + metric, zero_line)
        ax.set_title(f"{d.traffic.iloc[0]}: {metric}{tag}")
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, f"{metric}.png"), dpi=150)
        plt.close(fig)


def plot_combined(s, keys, outdir, zero_line=False, suffix="by_traffic"):
    os.makedirs(outdir, exist_ok=True)
    traffics = sorted(s.traffic.unique())
    for metric, d in s.groupby("metric"):
        fig, axes = plt.subplots(1, len(traffics),
                                 figsize=(5.2 * len(traffics), 4.2),
                                 sharey=True, squeeze=False)
        for ax, t in zip(axes[0], traffics):
            dt = d[d.traffic == t]
            if dt.empty:
                ax.set_visible(False)
                continue
            draw(ax, dt, keys, ("Δ " if zero_line else "") + metric, zero_line)
            ax.set_title(t)
        fig.suptitle(metric + (" (change vs 0% adoption)" if zero_line else ""))
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, f"{metric}_{suffix}.png"), dpi=150)
        plt.close(fig)


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", help="experiment folder, e.g. 3rd_nov_320mhz/exp1")
    ap.add_argument("--keys", nargs="*", default=None,
                    help=f"grouping columns (default: {DEFAULT_KEYS})")
    ap.add_argument("--metrics", nargs="*", default=None,
                    help="metric columns (default: built-in list)")
    a = ap.parse_args()

    df = load(a.out)
    keys = a.keys if a.keys is not None else DEFAULT_KEYS
    metrics = a.metrics if a.metrics is not None else \
        [m for m in DEFAULT_METRICS if m in df.columns]
    missing = [c for c in keys + metrics if c not in df.columns]
    if missing:
        sys.exit(f"Columns not in the raw CSVs: {missing}")
    if not metrics:
        sys.exit("No metric columns found; pass --metrics.")
    print(f"Grouping keys: {keys or '(none)'}")
    print(f"Metrics ({len(metrics)}): {metrics}")

    long = to_long(df, keys, metrics)
    summ = summarise(long, keys)
    pair = paired_vs_baseline(long, keys)
    if pair is None:
        print("No 0% adoption runs: paired outputs skipped.")

    # ---- per-traffic folders
    for t in sorted(summ.traffic.unique()):
        adir = os.path.join(a.out, t, "analysis")
        os.makedirs(adir, exist_ok=True)
        st = summ[summ.traffic == t]
        st.to_csv(os.path.join(adir, "exp1_summary_mean_ci.csv"), index=False)
        write_wide_tables(st, keys, os.path.join(adir, "tables"))
        plot_per_traffic(st, keys, os.path.join(adir, "plots"))
        if pair is not None:
            pt = pair[pair.traffic == t]
            pt.to_csv(os.path.join(adir, "exp1_paired_vs_0pct.csv"), index=False)
            plot_per_traffic(pt[pt.adoptionPct > 0], keys,
                             os.path.join(adir, "plots", "paired"),
                             tag=" (change vs 0%)", zero_line=True)
        print(f"  {t}: wrote {adir}")

    # ---- combined summary folder
    sdir = os.path.join(a.out, "summary")
    os.makedirs(sdir, exist_ok=True)
    # named *_ci_* (not *_mean_ci_*) so it does not overwrite the file the
    # bash script's built-in combiner writes from analyse_pedca.py output
    summ.to_csv(os.path.join(sdir, "exp1_summary_ci_all_traffic.csv"), index=False)
    plot_combined(summ, keys, os.path.join(sdir, "plots"))
    if pair is not None:
        pair.to_csv(os.path.join(sdir, "exp1_paired_vs_0pct_all_traffic.csv"),
                    index=False)
        plot_combined(pair[pair.adoptionPct > 0], keys,
                      os.path.join(sdir, "plots"), zero_line=True,
                      suffix="paired_by_traffic")
    print(f"Wrote combined outputs to {sdir}")


if __name__ == "__main__":
    main()
