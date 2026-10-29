#!/usr/bin/env python3
"""Experiment 2 graphs: EDCA (0 % P-EDCA) vs P-EDCA (100 %) at different loads.

Usage
    python3 exp2_graphs.py                       # uses the default paths below
    python3 exp2_graphs.py --summary PATH/exp2.csv --out PATH/graphs

Input   the summary CSV of experiment 2 (one row per AC per run; scenarioLabel looks like
        load_<L>_<traffic>_a<pct>_seed<S>_rep<R>)
Output  <out>/<traffic>/NN_*.png      graphs for one traffic type (cbr, poisson, poissonBurst)
        <out>/combined/NN_*_combined.png   the three traffic types side by side
        <out>/exp2_per_run_metrics.csv, exp2_summary_by_load.csv   the numbers behind the graphs

Graphs
    01 VO throughput            02 VO mean delay        03 VO p95 delay        04 VO p99 delay
    05 VO PDR                   06 throughput of all ACs (bar)   07 mean delay of all ACs (bar, log y)
    08 macDataAttempts (VO and all ACs)       09 macRetransmissions (VO and all ACs)

Lines/bars show the mean over seeds; the dots are the individual seeds.  Error bars (95 % Student-t CI)
are drawn only when there are at least 3 seeds - with 1-2 seeds a CI is meaningless, so look at the dots.
Delay graphs use a log y axis because delay spans orders of magnitude between light and heavy load.
Delay statistics only count delivered packets: read them together with the PDR graph.
macDataAttempts/macRetransmissions count data frames sent by the stations (DS-CTS and Stage-2 RTS
control frames are not included).
"""
import argparse, math, os, re, sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import NullFormatter, ScalarFormatter

DEFAULT_SUMMARY = "/Users/neharionaalice/Downloads/ns-3.48/results/exp2_sim_200/run_20261026_102852/summary/exp2.csv"
DEFAULT_OUT = "/Users/neharionaalice/Downloads/ns-3.48/results/exp2_sim_200/run_20261026_102852/graphs"

TRAFFIC_ORDER = ["cbr", "poisson", "poissonBurst"]
C_EDCA, C_PEDCA = "#d62728", "#1f77b4"
GROUPS = [(0, "EDCA (0% P-EDCA)", C_EDCA, "o"), (100, "P-EDCA (100%)", C_PEDCA, "s")]
LABEL = re.compile(r"load_(?P<load>[\d.]+)_")

# ----------------------------------------------------------------------------- statistics
try:
    from scipy import stats as _st
    def tq(n): return float(_st.t.ppf(0.975, n - 1)) if n > 1 else float("nan")
except Exception:
    _T = {2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228}
    def tq(n):
        df = n - 1
        return float("nan") if df < 1 else _T.get(df, 2.0)

def mean_ci(v):
    v = np.asarray([x for x in v if not np.isnan(x)], float); n = len(v)
    if n == 0: return np.nan, np.nan, 0
    m = float(v.mean())
    ci = tq(n) * float(v.std(ddof=1)) / math.sqrt(n) if n >= 3 else np.nan   # CI only with >= 3 seeds
    return m, ci, n

# ----------------------------------------------------------------------------- data
def load_summary(path):
    d = pd.read_csv(path)
    need = ["scenarioLabel", "ac", "trafficModel", "pedcaAdoptionRatio", "rngSeed", "rngRun", "stationsInAc"]
    miss = [c for c in need if c not in d.columns]
    if miss: sys.exit(f"{path}: missing columns {miss}")
    d["traffic"] = d.trafficModel
    d["pct"] = (d.pedcaAdoptionRatio * 100).round().astype(int)
    d["rep"] = d.rngSeed.astype(str) + "-" + d.rngRun.astype(str)
    ld = d.scenarioLabel.str.extract(LABEL)["load"].astype(float)
    if ld.isna().any():                                   # fall back to the VI row's per-AC load
        vi = d[d.ac == "AC_VI"].set_index("scenarioLabel").perAcOfferedLoadMbps
        ld = ld.fillna(d.scenarioLabel.map(vi))
    d["load"] = ld
    return d

def one(g, ac, col):
    x = g[g.ac == ac]
    return float(x[col].iloc[0]) if len(x) else np.nan

def run_metrics(d):
    rows = []
    for (tr, ld, pct, rep), g in d.groupby(["traffic", "load", "pct", "rep"]):
        vo = g[g.ac.isin(["AC_VO_LEGACY", "AC_VO_PEDCA"]) & (g.stationsInAc > 0)]
        if vo.empty: continue
        tx, rx = vo.txPackets.sum(), vo.rxPackets.sum()
        w = vo.rxPackets.to_numpy(float); dl = vo.meanDelayMs.to_numpy(float)
        ok = ~np.isnan(dl) & (w > 0)
        rec = {"VO": dict(thr=vo.throughputMbps.sum(), pdr=rx / tx if tx > 0 else np.nan,
                          delay=(dl[ok] * w[ok]).sum() / w[ok].sum() if ok.any() else np.nan,
                          p95=vo.p95DelayMs.iloc[0] if len(vo) == 1 else np.nan,
                          p99=vo.p99DelayMs.iloc[0] if len(vo) == 1 else np.nan,
                          att=vo.macDataAttempts.sum(), ret=vo.macRetransmissions.sum())}
        for nm, ac in (("VI", "AC_VI"), ("BE", "AC_BE"), ("BK", "AC_BK")):
            rec[nm] = dict(thr=one(g, ac, "throughputMbps"), pdr=one(g, ac, "pdr"), delay=one(g, ac, "meanDelayMs"),
                           p95=one(g, ac, "p95DelayMs"), p99=one(g, ac, "p99DelayMs"),
                           att=one(g, ac, "macDataAttempts"), ret=one(g, ac, "macRetransmissions"))
        rec["ALL"] = dict(thr=sum(rec[k]["thr"] for k in ("VO", "VI", "BE", "BK")), pdr=np.nan, delay=np.nan,
                          p95=np.nan, p99=np.nan,
                          att=sum(rec[k]["att"] for k in ("VO", "VI", "BE", "BK")),
                          ret=sum(rec[k]["ret"] for k in ("VO", "VI", "BE", "BK")))
        for grp, m in rec.items():
            rows.append(dict(traffic=tr, load=ld, pct=pct, rep=rep, group=grp, **m))
    return pd.DataFrame(rows)

def values(R, tr, grp, pct, load, m):
    x = R[(R.traffic == tr) & (R.group == grp) & (R.pct == pct) & (R.load == load)][m]
    return x.to_numpy(float)

# ----------------------------------------------------------------------------- plotting helpers
def fmt_load_axis(ax, loads, log_x=True):
    if log_x and len(loads) > 1 and min(loads) > 0:
        ax.set_xscale("log", base=2)
    ax.set_xticks(loads); ax.set_xticklabels([f"{l:g}" for l in loads])
    ax.xaxis.set_minor_formatter(NullFormatter()); ax.set_xlabel("offered load per AC (Mbit/s)", fontsize=9)
    ax.grid(alpha=.3); ax.tick_params(labelsize=9)

def draw_lines(ax, R, tr, grp, m, loads, log_y=False):
    for pct, lab, col, mk in GROUPS:
        xs, ms, es = [], [], []
        for L in loads:
            v = values(R, tr, grp, pct, L, m)
            mean, ci, n = mean_ci(v)
            if n == 0: continue
            xs.append(L); ms.append(mean); es.append(0 if np.isnan(ci) else ci)
            jitter = 0.97 if pct == 0 else 1.03
            ax.plot([L * jitter] * len(v), v, ls="none", marker=mk, mfc="none", mec=col, alpha=.45, markersize=5)
        if xs:
            ax.errorbar(xs, ms, yerr=es if any(es) else None, color=col, marker=mk, lw=1.8, capsize=3, label=lab)
    if log_y: ax.set_yscale("log")
    fmt_load_axis(ax, loads)

def draw_bars(ax, R, tr, grp, m, loads, log_y=False):
    xs = np.arange(len(loads)); w = 0.38
    for i, (pct, lab, col, mk) in enumerate(GROUPS):
        pos = xs + (i - .5) * w; ms, es = [], []
        for k, L in enumerate(loads):
            v = values(R, tr, grp, pct, L, m); mean, ci, n = mean_ci(v)
            ms.append(mean); es.append(0 if np.isnan(ci) else ci)
            if n: ax.plot([pos[k]] * len(v), v, ls="none", marker="o", color="k", markersize=3, alpha=.6, zorder=3)
        ax.bar(pos, np.nan_to_num(ms, nan=0.0), w, yerr=es if any(es) else None, color=col, capsize=2, label=lab, alpha=.9)
    ax.set_xticks(xs); ax.set_xticklabels([f"{l:g}" for l in loads]); ax.set_xlabel("offered load per AC (Mbit/s)", fontsize=9)
    ax.grid(alpha=.3, axis="y"); ax.tick_params(labelsize=9)
    if log_y: ax.set_yscale("log")

NOTE = "mean of seeds (hollow markers = individual seeds; error bars = 95% CI when ≥3 seeds)"

VO_GRAPHS = [("01_vo_throughput", "VO throughput", "throughput (Mbps)", "thr", False),
             ("02_vo_mean_delay", "VO mean delay", "mean delay (ms)", "delay", True),
             ("03_vo_p95_delay", "VO 95th-percentile delay", "p95 delay (ms)", "p95", True),
             ("04_vo_p99_delay", "VO 99th-percentile delay", "p99 delay (ms)", "p99", True),
             ("05_vo_pdr", "VO packet delivery ratio", "PDR", "pdr", False)]

def fig_vo_single(R, tr, loads, stem, title, ylabel, m, log_y, path, dpi):
    fig, ax = plt.subplots(figsize=(7.5, 5.2)); draw_lines(ax, R, tr, "VO", m, loads, log_y)
    ax.set_ylabel(ylabel + (" (log scale)" if log_y else ""), fontsize=9); ax.legend(fontsize=9)
    fig.suptitle(f"{title} vs load - {tr} traffic\n{NOTE}", fontsize=10); fig.tight_layout(rect=[0, 0, 1, .93])
    fig.savefig(path, dpi=dpi); plt.close(fig)

def fig_vo_combined(R, trs, loads, title, ylabel, m, log_y, path, dpi):
    fig, axs = plt.subplots(1, len(trs), figsize=(5.6 * len(trs), 5), sharey=True, squeeze=False)
    for ax, tr in zip(axs[0], trs):
        draw_lines(ax, R, tr, "VO", m, loads, log_y); ax.set_title(tr, fontsize=11)
    axs[0, 0].set_ylabel(ylabel + (" (log scale)" if log_y else ""), fontsize=9); axs[0, 0].legend(fontsize=9)
    fig.suptitle(f"{title} vs load - all traffic types\n{NOTE}", fontsize=10); fig.tight_layout(rect=[0, 0, 1, .92])
    fig.savefig(path, dpi=dpi); plt.close(fig)

ACS = [("VO", "VO"), ("VI", "VI"), ("BE", "BE"), ("BK", "BK")]

def fig_ac_bars_single(R, tr, loads, title, ylabel, m, log_y, path, dpi):
    fig, axs = plt.subplots(2, 2, figsize=(12, 8.5))
    for ax, (g, nm) in zip(axs.ravel(), ACS):
        draw_bars(ax, R, tr, g, m, loads, log_y); ax.set_title(nm, fontsize=11)
        ax.set_ylabel(ylabel + (" (log)" if log_y else ""), fontsize=9)
    axs[0, 0].legend(fontsize=9)
    fig.suptitle(f"{title} of all access categories - {tr} traffic\n{NOTE.replace('hollow markers', 'dots')}", fontsize=10)
    fig.tight_layout(rect=[0, 0, 1, .94]); fig.savefig(path, dpi=dpi); plt.close(fig)

def fig_ac_bars_combined(R, trs, loads, title, ylabel, m, log_y, path, dpi):
    fig, axs = plt.subplots(len(trs), 4, figsize=(18, 3.7 * len(trs)), squeeze=False)
    for i, tr in enumerate(trs):
        for j, (g, nm) in enumerate(ACS):
            ax = axs[i, j]; draw_bars(ax, R, tr, g, m, loads, log_y); ax.set_title(f"{tr}: {nm}", fontsize=10)
            if j == 0: ax.set_ylabel(ylabel + (" (log)" if log_y else ""), fontsize=9)
    axs[0, 0].legend(fontsize=8)
    fig.suptitle(f"{title} of all access categories - all traffic types\n{NOTE.replace('hollow markers', 'dots')}", fontsize=10)
    fig.tight_layout(rect=[0, 0, 1, .95]); fig.savefig(path, dpi=dpi); plt.close(fig)

def fig_mac_single(R, tr, loads, stem, title, m, path, dpi):
    fig, axs = plt.subplots(1, 2, figsize=(13, 5))
    for ax, (g, nm) in zip(axs, (("VO", "VO stations"), ("ALL", "all stations (VO+VI+BE+BK)"))):
        draw_lines(ax, R, tr, g, m, loads); ax.set_title(nm, fontsize=11); ax.set_ylabel(f"{title} (count per run)", fontsize=9)
    axs[0].legend(fontsize=9)
    fig.suptitle(f"{title} vs load - {tr} traffic\n{NOTE}", fontsize=10); fig.tight_layout(rect=[0, 0, 1, .92])
    fig.savefig(path, dpi=dpi); plt.close(fig)

def fig_mac_combined(R, trs, loads, title, m, path, dpi):
    fig, axs = plt.subplots(2, len(trs), figsize=(5.6 * len(trs), 8.5), squeeze=False)
    for j, tr in enumerate(trs):
        for i, (g, nm) in enumerate((("VO", "VO stations"), ("ALL", "all stations"))):
            ax = axs[i, j]; draw_lines(ax, R, tr, g, m, loads); ax.set_title(f"{tr}: {nm}", fontsize=10)
            if j == 0: ax.set_ylabel(f"{title} (count per run)", fontsize=9)
    axs[0, 0].legend(fontsize=9)
    fig.suptitle(f"{title} vs load - all traffic types\n{NOTE}", fontsize=10); fig.tight_layout(rect=[0, 0, 1, .94])
    fig.savefig(path, dpi=dpi); plt.close(fig)

# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--summary", default=DEFAULT_SUMMARY, help="path of exp2.csv")
    ap.add_argument("--out", default=DEFAULT_OUT, help="folder for the graphs")
    ap.add_argument("--dpi", type=int, default=150)
    ap.add_argument("--only", choices=["all", "per-traffic", "combined"], default="all",
                    help="all = 9 graphs x (3 traffic folders + combined) = 36; combined = only the 9 combined graphs; "
                         "per-traffic = only the 27 per-traffic graphs")
    a = ap.parse_args()
    if not os.path.isfile(a.summary): sys.exit(f"Summary file not found: {a.summary}")
    d = load_summary(a.summary); R = run_metrics(d)
    d = d[d.pct.isin([0, 100])]; R = R[R.pct.isin([0, 100])]
    trs = [t for t in TRAFFIC_ORDER if t in set(R.traffic)] + sorted(set(R.traffic) - set(TRAFFIC_ORDER))
    loads = sorted(R.load.unique())
    print(f"Traffic types: {trs}\nLoads (Mbit/s per AC): {[f'{l:g}' for l in loads]}\n"
          f"Adoption levels: {sorted(R.pct.unique())}   seeds/replicates per point: {R.groupby(['traffic','load','pct','group']).rep.nunique().min()}"
          f"-{R.groupby(['traffic','load','pct','group']).rep.nunique().max()}")
    if R.groupby(['traffic', 'load', 'pct', 'group']).rep.nunique().min() < 3:
        print("NOTE: fewer than 3 seeds per point -> no confidence intervals are drawn (individual seeds are shown as dots).")
    os.makedirs(a.out, exist_ok=True)
    R.to_csv(os.path.join(a.out, "exp2_per_run_metrics.csv"), index=False)
    rows = []
    for (tr, grp, pct, ld), g in R.groupby(["traffic", "group", "pct", "load"]):
        row = dict(traffic=tr, group=grp, adoption_pct=pct, load=ld, replicates=g.rep.nunique())
        for m in ("thr", "pdr", "delay", "p95", "p99", "att", "ret"):
            row[m + "_mean"], row[m + "_ci95"], _ = mean_ci(g[m])
        rows.append(row)
    pd.DataFrame(rows).to_csv(os.path.join(a.out, "exp2_summary_by_load.csv"), index=False)

    for tr in (trs if a.only in ("all", "per-traffic") else []):
        od = os.path.join(a.out, tr); os.makedirs(od, exist_ok=True)
        for stem, title, ylabel, m, log_y in VO_GRAPHS:
            fig_vo_single(R, tr, loads, stem, title, ylabel, m, log_y, os.path.join(od, stem + "_vs_load.png"), a.dpi)
        fig_ac_bars_single(R, tr, loads, "Throughput", "throughput (Mbps)", "thr", False, os.path.join(od, "06_all_ac_throughput_bar.png"), a.dpi)
        fig_ac_bars_single(R, tr, loads, "Mean delay", "mean delay (ms)", "delay", True, os.path.join(od, "07_all_ac_mean_delay_bar.png"), a.dpi)
        fig_mac_single(R, tr, loads, "08", "macDataAttempts", "att", os.path.join(od, "08_mac_data_attempts_vs_load.png"), a.dpi)
        fig_mac_single(R, tr, loads, "09", "macRetransmissions", "ret", os.path.join(od, "09_mac_retransmissions_vs_load.png"), a.dpi)
        print(f"  {tr}: 9 graphs -> {od}")
    if a.only == "per-traffic":
        print(f"Done. Graphs are in {a.out}"); return
    cd = os.path.join(a.out, "combined"); os.makedirs(cd, exist_ok=True)
    for stem, title, ylabel, m, log_y in VO_GRAPHS:
        fig_vo_combined(R, trs, loads, title, ylabel, m, log_y, os.path.join(cd, stem + "_vs_load_combined.png"), a.dpi)
    fig_ac_bars_combined(R, trs, loads, "Throughput", "throughput (Mbps)", "thr", False, os.path.join(cd, "06_all_ac_throughput_bar_combined.png"), a.dpi)
    fig_ac_bars_combined(R, trs, loads, "Mean delay", "mean delay (ms)", "delay", True, os.path.join(cd, "07_all_ac_mean_delay_bar_combined.png"), a.dpi)
    fig_mac_combined(R, trs, loads, "macDataAttempts", "att", os.path.join(cd, "08_mac_data_attempts_vs_load_combined.png"), a.dpi)
    fig_mac_combined(R, trs, loads, "macRetransmissions", "ret", os.path.join(cd, "09_mac_retransmissions_vs_load_combined.png"), a.dpi)
    print(f"  combined: 9 graphs -> {cd}\nDone. Graphs are in {a.out}")

if __name__ == "__main__":
    main()
