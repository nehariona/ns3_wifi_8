#!/usr/bin/env python3
"""
Plot P-EDCA results: 0% vs 100% adoption for every scenario.

Usage:
    python plot_exp3.py exp3_ac_ratio.csv                 # AC_VO figures (default)
    python plot_exp3.py exp3_ac_ratio.csv --ac ALL        # VO + BE + BK + VI
    python plot_exp3.py exp3_ac_ratio.csv --ac VI --linear
    python plot_exp3.py exp3_ac_ratio.csv --outdir plots --no-labels

What is plotted (one PNG + one PDF per metric):
  * x-axis : scenario
  * bars   : 0% adoption (all VO STAs legacy EDCA -> rows AC_VO_LEGACY)
             100% adoption (all VO STAs P-EDCA   -> rows AC_VO_PEDCA)
  * height : mean over the runs/seeds in the CSV; error bars = std dev
             (sample std, ddof=1; hidden when only one run exists)
For --ac BE/BK/VI the same AC is compared between the 0% and 100% runs.
"""
import argparse
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# (column, title, y-label, is_delay)
METRICS = [
    ("meanDelayMs", "Mean delay", "Mean delay (ms)", True),
    ("p99DelayMs", "99th percentile delay", "p99 delay (ms)", True),
    ("p95DelayMs", "95th percentile delay", "p95 delay (ms)", True),
    ("pdr", "Packet delivery ratio", "PDR", False),
    ("throughputMbps", "Throughput", "Throughput (Mbps)", False),
    ("macRetransmissions", "MAC retransmissions", "MAC retransmissions (count)", False),
    ("macDataAttempts", "MAC data attempts", "MAC data attempts (count)", False),
]

# Preferred scenario order (unknown scenarios are appended alphabetically)
SCENARIO_ORDER = [
    "Baseline",
    "Pyramid",
    "InvertedPyramid",
    "VO-heavy",
    "BK-heavy",
    "HighPriorityPolarized",
    "LowPriorityPolarized",
    "ExtremeSingleStation",
]

COLORS = {0: "#4C72B0", 100: "#DD8452"}
LABELS = {0: "0% P-EDCA (legacy EDCA)", 100: "100% P-EDCA"}


def load(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    needed = {"scenarioLabel", "ac", "pedcaAdoptionRatio", "stationsInAc"}
    missing = needed - set(df.columns)
    if missing:
        sys.exit(f"CSV is missing columns: {sorted(missing)}")
    # Normalise adoption to percent (CSV stores 0/1)
    df["adoptionPct"] = (df["pedcaAdoptionRatio"] * 100).round().astype(int)
    # Drop rows for ACs that have no stations in that scenario
    return df[df["stationsInAc"] > 0].copy()


def select_ac(df: pd.DataFrame, ac: str) -> pd.DataFrame:
    """Return rows for the AC being compared, one adoption level per row."""
    if ac == "VO":
        keep = ((df["adoptionPct"] == 0) & (df["ac"] == "AC_VO_LEGACY")) | (
            (df["adoptionPct"] == 100) & (df["ac"] == "AC_VO_PEDCA")
        )
        return df[keep]
    return df[df["ac"] == f"AC_{ac}"]


def scenario_order(present):
    ordered = [s for s in SCENARIO_ORDER if s in present]
    ordered += sorted(s for s in present if s not in SCENARIO_ORDER)
    return ordered


def plot_metric(sub, col, title, ylabel, is_delay, ac, outdir, log, labels):
    scenarios = scenario_order(sub["scenarioLabel"].unique())
    stats = (
        sub.groupby(["scenarioLabel", "adoptionPct"])[col]
        .agg(["mean", "std", "count"])
        .reindex(
            pd.MultiIndex.from_product([scenarios, [0, 100]], names=["s", "a"])
        )
    )

    x = np.arange(len(scenarios))
    width = 0.38
    fig, ax = plt.subplots(figsize=(11, 5.2))

    for i, pct in enumerate([0, 100]):
        means = stats.xs(pct, level="a")["mean"].reindex(scenarios).to_numpy()
        stds = stats.xs(pct, level="a")["std"].reindex(scenarios).to_numpy()
        counts = stats.xs(pct, level="a")["count"].reindex(scenarios).to_numpy()
        yerr = np.where(counts > 1, np.nan_to_num(stds), 0.0)
        pos = x + (i - 0.5) * width
        bars = ax.bar(
            pos,
            means,
            width,
            yerr=yerr,
            capsize=3,
            color=COLORS[pct],
            edgecolor="black",
            linewidth=0.6,
            label=LABELS[pct],
            error_kw={"elinewidth": 0.9},
        )
        if labels:
            for b, m, e in zip(bars, means, yerr):
                if np.isnan(m):
                    continue
                txt = f"{m:.2f}" if abs(m) < 100 else f"{m:.0f}"
                if col in ("macRetransmissions", "macDataAttempts"):
                    txt = f"{m:,.0f}"
                ax.annotate(
                    txt,
                    (b.get_x() + b.get_width() / 2, m + e),
                    ha="center",
                    va="bottom",
                    fontsize=7,
                    xytext=(0, 2),
                    textcoords="offset points",
                    rotation=90 if len(scenarios) > 6 else 0,
                )

    if is_delay and log:
        ax.set_yscale("log")
        ylabel += " [log scale]"
    elif col == "pdr":
        ax.set_ylim(0, 1.12)

    if col != "pdr":
        ax.margins(y=0.25)  # headroom so value labels are not clipped
    ax.set_xticks(x)
    ax.set_xticklabels(scenarios, rotation=25, ha="right")
    ax.set_ylabel(ylabel)
    ac_name = "AC_VO" if ac == "VO" else f"AC_{ac}"
    ax.set_title(f"{title} - {ac_name}: 0% vs 100% P-EDCA adoption")
    ax.grid(axis="y", linestyle=":", alpha=0.6)
    ax.set_axisbelow(True)
    ax.legend()
    fig.tight_layout()

    stem = f"{col}_{ac}"
    fig.savefig(outdir / f"{stem}.png", dpi=200)
    fig.savefig(outdir / f"{stem}.pdf")
    plt.close(fig)
    print(f"saved {outdir / (stem + '.png')}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", type=Path, help="exp3_ac_ratio.csv")
    ap.add_argument("--ac", default="VO", choices=["VO", "BE", "BK", "VI", "ALL"],
                    help="access category to plot (default VO; ALL = every AC)")
    ap.add_argument("--outdir", type=Path, default=Path("plots"))
    ap.add_argument("--linear", action="store_true", help="linear y-axis for delay plots (default: log)")
    ap.add_argument("--no-labels", action="store_true", help="hide value labels above bars")
    args = ap.parse_args()

    args.outdir.mkdir(parents=True, exist_ok=True)
    df = load(args.csv)

    acs = ["VO", "BE", "BK", "VI"] if args.ac == "ALL" else [args.ac]
    for ac in acs:
        sub = select_ac(df, ac)
        if sub.empty:
            print(f"no data for AC {ac}, skipping")
            continue
        for col, title, ylabel, is_delay in METRICS:
            if col not in sub.columns:
                print(f"column {col} not in CSV, skipping")
                continue
            plot_metric(sub, col, title, ylabel, is_delay, ac, args.outdir,
                        log=not args.linear, labels=not args.no_labels)


if __name__ == "__main__":
    main()
