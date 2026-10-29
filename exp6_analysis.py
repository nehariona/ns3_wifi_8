#!/usr/bin/env python3
"""
analyze_exp6.py - summary tables and graphs for Experiment 6
(EDCA 0 % vs P-EDCA 100 % adoption, number of stations scaling).

Usage:
    python3 analyze_exp6.py --csv exp6_cumulative.csv --out analysis/

Needs: pandas, numpy, matplotlib   (pip3 install pandas numpy matplotlib)

Handles both CSV layouts:
  * one row per (run, AC)           -> per-AC plots + an ALL aggregate is built
  * one row per run with ac == ALL  -> used directly
"""
import argparse
import os
import re
import sys

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

AC_ORDER = ["VO", "VO_LEGACY", "VO_PEDCA", "VI", "BE", "BK", "ALL"]
AC_NAME = {"VO": "Voice (VO)", "VO_LEGACY": "VO - legacy EDCA STAs", "VO_PEDCA": "VO - P-EDCA STAs", "VI": "Video (VI)", "BE": "Best effort (BE)",
           "BK": "Background (BK)", "ALL": "All ACs"}
STRING_COLS = {"protocol", "scenarioLabel", "ac", "loadPolicy", "trafficModel",
               "stationsInAc", "runDir"}

# (column, axis label, prefer log-y if delay-like)
METRICS = [
    ("throughputMbps",     "Throughput (Mbps)",          False),
    ("payloadGoodputMbps", "Payload goodput (Mbps)",     False),
    ("pdr",                "Packet delivery ratio",      False),
    ("packetLossRate",     "Packet loss rate",           False),
    ("meanDelayMs",        "Mean delay (ms)",            True),
    ("meanJitterMs",       "Mean jitter (ms)",           True),
    ("p95DelayMs",         "95th pct delay (ms)",        True),
    ("p99DelayMs",         "99th pct delay (ms)",        True),
    ("p999DelayMs",        "99.9th pct delay (ms)",      True),
    ("retxRatio",          "MAC retransmission ratio",   False),
]
# lower is better for these when computing "improvement"
LOWER_BETTER = {"packetLossRate", "meanDelayMs", "meanJitterMs", "p95DelayMs",
                "p99DelayMs", "p999DelayMs", "retxRatio"}

STYLE = {  # cfg label -> (colour, marker)
    "EDCA (0%)":    ("#d62728", "o"),
    "P-EDCA (100%)": ("#1f77b4", "s"),
}


# --------------------------------------------------------------------------- #
def norm_ac(x):
    s = str(x).upper()
    if "VO" in s and "LEGACY" in s:
        return "VO_LEGACY"
    if "VO" in s and "PEDCA" in s.replace("-", "").replace("_", ""):
        return "VO_PEDCA"
    for k in ("VO", "VI", "BE", "BK"):
        if re.search(rf"(^|[^A-Z]){k}([^A-Z]|$)", s) or s.endswith(k):
            return k
    if any(t in s for t in ("ALL", "TOTAL", "AGG", "OVERALL")):
        return "ALL"
    return s


def cfg_label(pct):
    pct = int(round(pct))
    return "EDCA (0%)" if pct == 0 else f"P-EDCA ({pct}%)"


def load(csv_path):
    df = pd.read_csv(csv_path, skipinitialspace=True)
    df.columns = [c.strip() for c in df.columns]
    for c in df.columns:
        if c not in STRING_COLS:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    if "ac" not in df.columns:
        df["ac"] = "ALL"
    df["ac"] = df["ac"].map(norm_ac)

    ratio = df["pedcaAdoptionRatio"].astype(float)
    pct = np.where(ratio <= 1.0, ratio * 100.0, ratio)
    df["adoptionPct"] = np.round(pct).astype(int)
    df["cfg"] = [cfg_label(p) for p in df["adoptionPct"]]

    if {"macRetransmissions", "macDataAttempts"} <= set(df.columns):
        df["retxRatio"] = df["macRetransmissions"] / df["macDataAttempts"].replace(0, np.nan)
    return df


RUN_KEY = ["cfg", "numStations", "rngSeed", "rngRun"]


def fix_vo_groups(df):
    """Drop empty AC groups (e.g. the P-EDCA VO group at 0 % adoption) and merge the
    single remaining VO sub-group of a run into plain 'VO'.  Averaging an empty
    group with a real one halves throughput/PDR, so empties must go first."""
    if "txPackets" in df.columns:
        empty = df["txPackets"].fillna(0) == 0
    else:
        empty = df["throughputMbps"].fillna(0) == 0
    df = df[~(empty & df["ac"].isin(["VO_LEGACY", "VO_PEDCA"]))].copy()
    sub = df["ac"].isin(["VO_LEGACY", "VO_PEDCA"])
    n_sub = sub.groupby([df[k] for k in RUN_KEY]).transform("sum")
    has_vo = (df["ac"] == "VO").groupby([df[k] for k in RUN_KEY]).transform("any")
    df.loc[sub & (n_sub == 1) & ~has_vo, "ac"] = "VO"
    return df


def add_all_aggregate(df):
    """Build an ALL row per run when the simulator only wrote per-AC rows."""
    if (df["ac"] == "ALL").any():
        return df
    per_ac = df[df["ac"].isin(["VO", "VO_LEGACY", "VO_PEDCA", "VI", "BE", "BK"])]
    if per_ac.empty:
        return df
    sums = [c for c in ("throughputMbps", "payloadGoodputMbps", "txPackets", "rxPackets",
                        "txBytes", "rxBytes", "flowMonitorLostPackets") if c in df.columns]
    rows = []
    for key, g in per_ac.groupby(RUN_KEY, dropna=False):
        r = g.iloc[0].copy()
        r["ac"] = "ALL"
        for c in sums:
            r[c] = g[c].sum()
        if {"txPackets", "rxPackets"} <= set(sums) and r["txPackets"] > 0:
            r["pdr"] = r["rxPackets"] / r["txPackets"]
            r["packetLossRate"] = 1.0 - r["pdr"]
        w = g["rxPackets"] if "rxPackets" in g else None
        for c in ("meanDelayMs", "meanJitterMs"):
            if c in g and w is not None and w.sum() > 0:
                r[c] = np.average(g[c].fillna(0), weights=w)
        for c in ("p95DelayMs", "p99DelayMs", "p999DelayMs"):
            if c in r.index:
                r[c] = np.nan     # percentiles cannot be aggregated from per-AC values
        rows.append(r)
    return pd.concat([df, pd.DataFrame(rows)], ignore_index=True)


def summarise(df, metrics):
    cols = [m for m in metrics if m in df.columns]
    g = df.groupby(["cfg", "adoptionPct", "numStations", "ac"], dropna=False)
    mean = g[cols].mean().add_suffix("_mean")
    std = g[cols].std(ddof=1).add_suffix("_std")
    n = g.size().rename("nRuns")
    out = pd.concat([mean, std, n], axis=1).reset_index()
    return out.sort_values(["ac", "adoptionPct", "numStations"])


# --------------------------------------------------------------------------- #
def plot_metric_grid(summ, metric, ylabel, logy, outdir):
    if f"{metric}_mean" not in summ.columns or summ[f"{metric}_mean"].dropna().empty:
        return
    acs = [a for a in AC_ORDER if a in set(summ["ac"])]
    ncols = 3
    nrows = int(np.ceil(len(acs) / ncols))
    fig, axes = plt.subplots(nrows, ncols, figsize=(5.2 * ncols, 3.9 * nrows), squeeze=False)
    xs_all = sorted(summ["numStations"].unique())
    for i, ac in enumerate(acs):
        ax = axes[i // ncols][i % ncols]
        for cfg, grp in summ[summ["ac"] == ac].groupby("cfg"):
            grp = grp.sort_values("numStations")
            col, mk = STYLE.get(cfg, (None, "^"))
            ax.errorbar(grp["numStations"], grp[f"{metric}_mean"],
                        yerr=grp[f"{metric}_std"].fillna(0), color=col, marker=mk,
                        capsize=3, lw=1.8, ms=6, label=cfg)
        ax.set_title(AC_NAME.get(ac, ac))
        ax.set_xlabel("Total number of stations")
        ax.set_ylabel(ylabel)
        ax.set_xticks(xs_all)
        ax.grid(alpha=0.3)
        vals = summ.loc[summ["ac"] == ac, f"{metric}_mean"]
        if logy and (vals > 0).all() and vals.max() / max(vals.min(), 1e-12) > 20:
            ax.set_yscale("log")
        if i == 0:
            ax.legend()
    for j in range(len(acs), nrows * ncols):
        axes[j // ncols][j % ncols].axis("off")
    fig.suptitle(f"{ylabel} vs number of stations  (mean ± 1 SD over seeds)", y=1.0)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, f"{metric}_by_ac.png"), dpi=200, bbox_inches="tight")
    plt.close(fig)


def plot_vo_focus(summ, outdir):
    """Single-row figure with the four headline VO metrics."""
    vo = summ[summ["ac"] == "VO"]
    if vo.empty:
        return
    picks = [m for m in ("throughputMbps", "pdr", "meanDelayMs", "p99DelayMs")
             if f"{m}_mean" in vo.columns and vo[f"{m}_mean"].notna().any()]
    if not picks:
        return
    labels = {m: l for m, l, _ in METRICS}
    fig, axes = plt.subplots(1, len(picks), figsize=(4.8 * len(picks), 3.8), squeeze=False)
    for ax, m in zip(axes[0], picks):
        for cfg, grp in vo.groupby("cfg"):
            grp = grp.sort_values("numStations")
            col, mk = STYLE.get(cfg, (None, "^"))
            ax.errorbar(grp["numStations"], grp[f"{m}_mean"], yerr=grp[f"{m}_std"].fillna(0),
                        color=col, marker=mk, capsize=3, lw=1.8, label=cfg)
        ax.set_xlabel("Total number of stations")
        ax.set_ylabel(labels[m])
        ax.set_xticks(sorted(vo["numStations"].unique()))
        ax.grid(alpha=0.3)
    axes[0][0].legend()
    fig.suptitle("Voice AC: EDCA vs P-EDCA", y=1.02)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "vo_headline.png"), dpi=200, bbox_inches="tight")
    plt.close(fig)


def improvement_table(summ, outdir):
    """P-EDCA(100 %) relative to EDCA(0 %), per AC and station count."""
    base = summ[summ["adoptionPct"] == 0]
    test = summ[summ["adoptionPct"] == 100]
    if base.empty or test.empty:
        return None
    rows = []
    for (ac, n), b in base.groupby(["ac", "numStations"]):
        t = test[(test["ac"] == ac) & (test["numStations"] == n)]
        if t.empty:
            continue
        b, t = b.iloc[0], t.iloc[0]
        row = {"ac": ac, "numStations": n}
        for m, _, _ in METRICS:
            k = f"{m}_mean"
            if k in summ.columns and pd.notna(b[k]) and pd.notna(t[k]) and b[k] != 0:
                row[f"{m}_EDCA"] = b[k]
                row[f"{m}_PEDCA"] = t[k]
                row[f"{m}_changePct"] = 100.0 * (t[k] - b[k]) / abs(b[k])
        rows.append(row)
    imp = pd.DataFrame(rows)
    imp.to_csv(os.path.join(outdir, "exp6_pedca_vs_edca.csv"), index=False)
    return imp


def plot_improvement(imp, outdir):
    if imp is None or imp.empty:
        return
    vo = imp[imp["ac"] == "VO"].sort_values("numStations")
    picks = [m for m in ("throughputMbps", "pdr", "meanDelayMs", "p99DelayMs")
             if f"{m}_changePct" in vo.columns]
    if vo.empty or not picks:
        return
    x = np.arange(len(vo))
    w = 0.8 / len(picks)
    fig, ax = plt.subplots(figsize=(8, 4.2))
    for i, m in enumerate(picks):
        ax.bar(x + i * w, vo[f"{m}_changePct"], w, label=m)
    ax.axhline(0, color="k", lw=0.8)
    ax.set_xticks(x + w * (len(picks) - 1) / 2)
    ax.set_xticklabels(vo["numStations"].astype(int))
    ax.set_xlabel("Total number of stations")
    ax.set_ylabel("Change, P-EDCA vs EDCA (%)")
    ax.set_title("Voice AC: relative change when VO adopts P-EDCA\n"
                 "(delay: negative = better;  throughput/PDR: positive = better)")
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3, axis="y")
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "vo_relative_change.png"), dpi=200)
    plt.close(fig)


def plot_overhead(df, outdir):
    """MAC-level counters are run-wide, so take one row per run."""
    run = df[df["ac"] == "ALL"] if (df["ac"] == "ALL").any() else df
    run = run.drop_duplicates(subset=RUN_KEY)
    cols = [c for c in ("dsCtsTransmissions", "stage2RtsTransmissions") if c in run.columns]
    p = run[run["adoptionPct"] > 0]
    if cols and not p.empty and p[cols].notna().any().any():
        g = p.groupby("numStations")[cols].agg(["mean", "std"])
        fig, ax = plt.subplots(figsize=(6.2, 4))
        for c in cols:
            ax.errorbar(g.index, g[(c, "mean")], yerr=g[(c, "std")].fillna(0),
                        marker="o", capsize=3, label=c)
        ax.set_xlabel("Total number of stations")
        ax.set_ylabel("Frames per run")
        ax.set_title("P-EDCA control-frame overhead")
        ax.set_xticks(sorted(p["numStations"].unique()))
        ax.grid(alpha=0.3)
        ax.legend()
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, "pedca_control_overhead.png"), dpi=200)
        plt.close(fig)


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True, help="cumulative CSV from exp6_full_script_final.sh")
    ap.add_argument("--out", default=None, help="output folder (default: <csv dir>/analysis)")
    a = ap.parse_args()

    outdir = a.out or os.path.join(os.path.dirname(os.path.abspath(a.csv)), "analysis")
    os.makedirs(outdir, exist_ok=True)

    df = load(a.csv)
    missing = [c for c in ("pedcaAdoptionRatio", "numStations") if c not in df.columns]
    if missing:
        sys.exit(f"CSV is missing required column(s): {missing}")
    df = fix_vo_groups(df)
    df = add_all_aggregate(df)

    metric_cols = [m for m, _, _ in METRICS]
    extra = [c for c in ("txPackets", "rxPackets", "macDataAttempts", "macRetransmissions",
                         "dsCtsTransmissions", "stage2RtsTransmissions") if c in df.columns]
    summ = summarise(df, metric_cols + extra)
    summ.to_csv(os.path.join(outdir, "exp6_summary_mean_std.csv"), index=False)

    for m, label, logy in METRICS:
        plot_metric_grid(summ, m, label, logy, outdir)
    plot_vo_focus(summ, outdir)
    imp = improvement_table(summ, outdir)
    plot_improvement(imp, outdir)
    plot_overhead(df, outdir)

    print(f"Runs read        : {df.drop_duplicates(subset=RUN_KEY).shape[0]}")
    print(f"Configurations   : {sorted(df['cfg'].unique())}")
    print(f"Station counts   : {[int(v) for v in sorted(df['numStations'].dropna().unique())]}")
    print(f"Runs per point   : {summ['nRuns'].min()} - {summ['nRuns'].max()}")
    if imp is not None and not imp.empty:
        vo = imp[imp["ac"] == "VO"]
        cols = ["numStations"] + [c for c in vo.columns if c.endswith("_changePct")
                                  and c.split("_")[0] in ("throughputMbps", "pdr", "meanDelayMs", "p99DelayMs")]
        if not vo.empty:
            print("\nVO: P-EDCA vs EDCA (% change)")
            print(vo[cols].round(2).to_string(index=False))
    print(f"\nOutputs written to: {outdir}")


if __name__ == "__main__":
    main()