#!/usr/bin/env python3
"""Merge raw per-run CSVs from run_pedca_sweep.sh, compute mean +/- 95% CI
across RngRun replicates, and plot adoption curves.

Usage: python3 analyse_pedca.py results/sweep/raw --out results/sweep/analysis
Needs: pandas, numpy, matplotlib (scipy optional for exact t quantiles).
"""
import argparse, glob, os, re
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

try:
    from scipy import stats
    def tq(n): return stats.t.ppf(0.975, n - 1) if n > 1 else np.nan
except ImportError:
    _T = {2: 12.71, 3: 4.30, 4: 3.18, 5: 2.78, 6: 2.57, 7: 2.45, 8: 2.36, 9: 2.31, 10: 2.26,
          15: 2.14, 20: 2.09, 30: 2.05}
    def tq(n):
        if n < 2: return np.nan
        k = max(x for x in _T if x <= n) if n >= 2 else 2
        return _T[k] if n < 30 else 1.96

FNAME = re.compile(r"L(?P<load>[\d.]+)_D(?P<ampdu_off>[01])_(?P<label>.+)_run(?P<run>\d+)\.csv$")
FNAME_RAW_LABEL = re.compile(r"_seed\d+_run\d+$")


def load(raw_dir):
    frames = []
    for f in sorted(glob.glob(os.path.join(raw_dir, "*.csv"))):
        m = FNAME.search(os.path.basename(f))
        if not m or os.path.getsize(f) == 0:
            continue
        d = pd.read_csv(f)
        d["load"] = float(m["load"])
        d["ampdu"] = "disabled" if m["ampdu_off"] == "1" else "enabled"
        d["scenario"] = m["label"]
        d["run"] = int(m["run"])
        frames.append(d)
    if not frames:
        raise SystemExit(f"No usable CSVs in {raw_dir}")
    d = pd.concat(frames, ignore_index=True)
    key = ["load", "ampdu", "scenario", "run", "ac"]
    n0 = len(d)
    d = d.drop_duplicates(subset=key, keep="first").reset_index(drop=True)
    if len(d) < n0:
        print(f"WARNING: dropped {n0 - len(d)} duplicate result rows (a run was appended twice).")
    return d


def add_vo_total(d):
    """Add an AC_VO_ALL row per run (legacy + P-EDCA combined)."""
    key = ["load", "ampdu", "scenario", "run"]
    vo = d[d.ac.isin(["AC_VO_LEGACY", "AC_VO_PEDCA"])].copy()
    rows = []
    for k, g in vo.groupby(key):
        tx, rx = g.txPackets.sum(), g.rxPackets.sum()
        w = g.rxPackets.replace(0, np.nan)
        r = g.iloc[0].copy()
        r["ac"] = "AC_VO_ALL"
        r["throughputMbps"] = g.throughputMbps.sum()
        r["payloadGoodputMbps"] = g.payloadGoodputMbps.sum()
        r["stationsInAc"] = g.stationsInAc.sum()
        r["pdr"] = rx / tx if tx else np.nan
        r["meanDelayMs"] = np.nansum(g.meanDelayMs.fillna(0) * g.rxPackets) / rx if rx else np.nan
        r["p99DelayMs"] = g.p99DelayMs.max(skipna=True)  # conservative upper bound
        att, rt = g.macDataAttempts.sum(), g.macRetransmissions.sum()
        r["macDataAttempts"], r["macRetransmissions"] = att, rt
        rows.append(r)
    return pd.concat([d, pd.DataFrame(rows)], ignore_index=True)


def summarise(d):
    d = d.copy()
    d["retxRatio"] = d.macRetransmissions / d.macDataAttempts.replace(0, np.nan)
    d["adoptionPct"] = d.pedcaAdoptionRatio * 100
    # Total network throughput per run
    tot = (d[d.ac.isin(["AC_BE", "AC_BK", "AC_VI", "AC_VO_ALL"])]
           .groupby(["load", "ampdu", "scenario", "run"], as_index=False).throughputMbps.sum())
    tot["ac"] = "ALL"; tot = tot.rename(columns={"throughputMbps": "throughputMbps"})
    meta = d.drop_duplicates(["load", "ampdu", "scenario", "run"])[
        ["load", "ampdu", "scenario", "run", "adoptionPct", "protocol"]]
    tot = tot.merge(meta, on=["load", "ampdu", "scenario", "run"])
    d = pd.concat([d, tot], ignore_index=True)

    metrics = ["throughputMbps", "payloadGoodputMbps", "pdr", "meanDelayMs", "p95DelayMs",
               "p99DelayMs", "meanJitterMs", "retxRatio", "deliveredWithin10msRatio",
               "deliveredWithin20msRatio", "dsCtsTransmissions",
               "stage2RtsTransmissions"]
    metrics = [m for m in metrics if m in d.columns]
    rows = []
    for (load_, amp, sc, ac), g in d.groupby(["load", "ampdu", "scenario", "ac"]):
        if g.get("stationsInAc", pd.Series([1])).iloc[0] == 0 and ac != "ALL":
            continue
        row = dict(load=load_, ampdu=amp, scenario=sc, ac=ac,
                   adoptionPct=g.adoptionPct.iloc[0], n=len(g))
        for m in metrics:
            x = g[m].dropna()
            row[m + "_mean"] = x.mean() if len(x) else np.nan
            row[m + "_ci95"] = (tq(len(x)) * x.std(ddof=1) / np.sqrt(len(x))) if len(x) > 1 else np.nan
        rows.append(row)
    return pd.DataFrame(rows).sort_values(["ampdu", "load", "ac", "adoptionPct"])


def plot(s, out):
    panels = [("AC_VO_ALL", "pdr_mean", "pdr_ci95", "VO (all) PDR"),
              ("AC_VO_ALL", "meanDelayMs_mean", "meanDelayMs_ci95", "VO (all) mean delay [ms]"),
              ("AC_VO_LEGACY", "pdr_mean", "pdr_ci95", "Legacy VO PDR"),
              ("AC_VO_PEDCA", "pdr_mean", "pdr_ci95", "P-EDCA VO PDR"),
              ("AC_BE", "throughputMbps_mean", "throughputMbps_ci95", "BE throughput [Mbps]"),
              ("AC_VI", "meanDelayMs_mean", "meanDelayMs_ci95", "VI mean delay [ms]"),
              ("ALL", "throughputMbps_mean", "throughputMbps_ci95", "Total throughput [Mbps]"),
              ("AC_VO_PEDCA", "retxRatio_mean", "retxRatio_ci95", "P-EDCA VO retx ratio")]
    for amp, sa in s.groupby("ampdu"):
        fig, axs = plt.subplots(2, 4, figsize=(18, 8))
        for ax, (ac, m, c, title) in zip(axs.ravel(), panels):
            for load_, g in sa[sa.ac == ac].groupby("load"):
                g = g.sort_values("adoptionPct")
                ax.errorbar(g.adoptionPct, g[m], yerr=g[c], marker="o", capsize=3,
                            label=f"{load_:g} Mbps/AC")
            ax.set_title(title); ax.set_xlabel("P-EDCA adoption among VO stations [%]")
            ax.grid(alpha=.3)
        axs[0, 0].legend(fontsize=8)
        fig.suptitle(f"P-EDCA adoption sweep - A-MPDU {amp} (mean +/- 95% CI)")
        fig.tight_layout()
        fig.savefig(os.path.join(out, f"adoption_ampdu_{amp}.png"), dpi=130)
        plt.close(fig)


def saturation_report(s, out):
    """Flag points where results are dominated by saturation / queue expiry."""
    r = s[s.ac.isin(["AC_BE", "AC_BK", "AC_VI", "AC_VO_ALL"])].copy()
    r["queueCapped"] = r.get("p99DelayMs_mean", 0) >= 499
    r["lowPdr"] = r.pdr_mean < 0.9
    r[(r.queueCapped) | (r.lowPdr)][
        ["ampdu", "load", "scenario", "ac", "pdr_mean", "meanDelayMs_mean", "p99DelayMs_mean"]
    ].to_csv(os.path.join(out, "saturated_points.csv"), index=False)


def _ci(x):
    x = pd.Series(x).dropna()
    n = len(x)
    if n < 2:
        return x.mean() if n else np.nan, np.nan, n
    return x.mean(), tq(n) * x.std(ddof=1) / np.sqrt(n), n


def paired(d, out):
    """Paired analysis using shared random streams (same RngRun => same traffic).
    1) adoption level minus the 0% scenario of the same family, per run.
    2) P-EDCA VO minus legacy VO inside the same mixed scenario, per run."""
    d = d.copy()
    d["family"] = d.scenario.str.replace(r"_\d+pct$", "", regex=True)
    d["retxRatio"] = d.macRetransmissions / d.macDataAttempts.replace(0, np.nan)
    d["adoptionPct"] = d.pedcaAdoptionRatio * 100
    mets = [m for m in ["pdr", "meanDelayMs", "p95DelayMs", "p99DelayMs", "meanJitterMs", "retxRatio",
                           "deliveredWithin10msRatio", "deliveredWithin20msRatio", "throughputMbps"] if m in d.columns]
    k = ["load", "ampdu", "family", "run"]

    # 1) vs 0% baseline
    rows = []
    for ac in ["AC_VO_ALL", "AC_VI", "AC_BE", "AC_BK"]:
        a = d[d.ac == ac]
        base = a[a.adoptionPct == 0].set_index(k)[mets]
        for (ld, amp, fam, pct), g in a[a.adoptionPct > 0].groupby(["load", "ampdu", "family", "adoptionPct"]):
            gg = g.set_index(k)[mets]
            diff = (gg - base.reindex(gg.index)).dropna(how="all")
            r = dict(load=ld, ampdu=amp, family=fam, ac=ac, adoptionPct=pct, n=len(diff))
            for m in mets:
                mean, ci, _ = _ci(diff[m])
                r[m + "_diff"], r[m + "_diff_ci95"] = mean, ci
            rows.append(r)
    pd.DataFrame(rows).to_csv(os.path.join(out, "paired_vs_baseline.csv"), index=False)

    # 2) P-EDCA VO vs legacy VO in the same scenario
    p = d[(d.ac == "AC_VO_PEDCA") & (d.stationsInAc > 0)].set_index(k + ["scenario"])[mets]
    l = d[(d.ac == "AC_VO_LEGACY") & (d.stationsInAc > 0)].set_index(k + ["scenario"])[mets]
    p = p[p.index.isin(l.index)]
    diff = (p - l.reindex(p.index)).dropna(how="all").reset_index()
    rows = []
    for (ld, amp, sc), g in diff.groupby(["load", "ampdu", "scenario"]):
        r = dict(load=ld, ampdu=amp, scenario=sc, n=len(g))
        for m in mets:
            mean, ci, _ = _ci(g[m])
            r[m + "_diff"], r[m + "_diff_ci95"] = mean, ci
        rows.append(r)
    pd.DataFrame(rows).to_csv(os.path.join(out, "paired_pedca_vs_legacy.csv"), index=False)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("raw_dir")
    ap.add_argument("--out", default="analysis")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    d = add_vo_total(load(a.raw_dir))
    d.to_csv(os.path.join(a.out, "merged_all_runs.csv"), index=False)
    s = summarise(d)
    s.to_csv(os.path.join(a.out, "summary_mean_ci.csv"), index=False)
    plot(s, a.out)
    saturation_report(s, a.out)
    paired(d, a.out)
    print(f"Runs merged: {d.groupby(['load','ampdu','scenario']).run.nunique().min()}-"
          f"{d.groupby(['load','ampdu','scenario']).run.nunique().max()} per point")
    print(f"Wrote summary, plots and saturated_points.csv to {a.out}")
