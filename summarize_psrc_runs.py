#!/usr/bin/env python3
"""Summarise P-EDCA experiment folders (one folder per PSRC value).

Usage:
  python3 summarize_psrc_runs.py DIR [DIR ...] [--out OUTDIR]

Each DIR is an output folder of run_exp1_complete.sh (it contains <traffic>/raw/*.csv).
PSRC / QSRC / CW values are read from the CSV columns, not from the folder name.

Writes into OUTDIR (default: psrc_summary/ next to the first DIR):
  summary_long.csv         one row per traffic, PSRC, adoption, AC  (mean, std, n over replicates)
  tables.md                the tables below as Markdown
  table_<traffic>_*.csv    the same tables as CSV
"""
import argparse, glob, os, sys
import numpy as np
import pandas as pd

ap = argparse.ArgumentParser()
ap.add_argument("dirs", nargs="+")
ap.add_argument("--out", default=None)
a = ap.parse_args()

frames = []
for d in a.dirs:
    files = sorted(glob.glob(os.path.join(d, "**", "raw", "*.csv"), recursive=True))
    if not files:
        print(f"WARNING: no raw CSV files under {d}", file=sys.stderr); continue
    for f in files:
        try:
            x = pd.read_csv(f)
        except Exception as e:
            print("skip", f, e, file=sys.stderr); continue
        x["srcDir"] = os.path.basename(os.path.normpath(d))
        x["replicate"] = os.path.splitext(os.path.basename(f))[0].rsplit("run", 1)[-1]
        frames.append(x)
if not frames:
    sys.exit("No data found.")
df = pd.concat(frames, ignore_index=True)
df["adoption"] = (100 * df["nVoPedca"] / (df["nVoPedca"] + df["nVoLegacy"])).round().astype(int)
df = df.rename(columns={"pedcaPsrcThreshold": "psrc", "pedcaQsrcThreshold": "qsrc"})
# an AC class with no stations (e.g. AC_VO_PEDCA at 0 % adoption) is absent, not "zero"
df = df[df["stationsInAc"] > 0].copy()

out = a.out or os.path.join(os.path.dirname(os.path.normpath(a.dirs[0])), "psrc_summary")
os.makedirs(out, exist_ok=True)

# the 0 % point has no P-EDCA STA, so it does not depend on PSRC: reuse it for every PSRC
psrcs = sorted(df.loc[df.adoption > 0, "psrc"].unique())
base = df[df.adoption == 0].drop_duplicates(subset=["trafficModel", "replicate", "ac"])  # each folder repeated it
if len(psrcs) and not base.empty:
    parts = [df[df.adoption > 0]]
    for p in psrcs:
        b = base.copy(); b["psrc"] = p; parts.append(b)
    df = pd.concat(parts, ignore_index=True)

metrics = ["throughputMbps", "pdr", "meanDelayMs", "p99DelayMs", "p999DelayMs",
           "macRetransmissions", "macDataAttempts", "dsCtsTransmissions", "stage2RtsTransmissions",
           "txPackets", "rxPackets"]
metrics = [m for m in metrics if m in df.columns]
keys = ["trafficModel", "psrc", "adoption", "ac"]
g = df.groupby(keys)
long = g[metrics].mean()
for m in ("pdr", "p99DelayMs", "throughputMbps"):
    long[m + "_std"] = g[m].std()
long["n"] = g.size()
long = long.reset_index()
long.to_csv(os.path.join(out, "summary_long.csv"), index=False)

# per-replicate pooled VO class (legacy + P-EDCA) and totals
rep_keys = ["trafficModel", "psrc", "adoption", "srcDir", "replicate"]
vo = df[df.ac.isin(["AC_VO_LEGACY", "AC_VO_PEDCA"])].groupby(rep_keys).agg(
    tx=("txPackets", "sum"), rx=("rxPackets", "sum"), tput=("throughputMbps", "sum")).reset_index()
vo["pdr"] = vo.rx / vo.tx
tot = df.groupby(rep_keys).agg(total=("throughputMbps", "sum")).reset_index()

def fmt(m, s=None, nd=3):
    if pd.isna(m): return "–"
    return f"{m:.{nd}f}" + (f" ± {s:.{nd}f}" if s is not None and not pd.isna(s) else "")

def md(table):
    cols = list(table.columns)
    lines = ["| " + " | ".join(cols) + " |", "|" + "|".join("---" for _ in cols) + "|"]
    for _, r in table.iterrows():
        lines.append("| " + " | ".join(str(r[c]) for c in cols) + " |")
    return "\n".join(lines)

def cell(traffic, p, ad, ac, m, nd=3):
    r = long[(long.trafficModel == traffic) & (long.psrc == p) & (long.adoption == ad) & (long.ac == ac)]
    if r.empty: return "–"
    r = r.iloc[0]
    return fmt(r[m], r.get(m + "_std"), nd)

doc = ["# P-EDCA PSRC sweep: summary tables",
       "", "Values are mean ± std over replicates. `–` = no such stations / not run.",
       f"Source folders: {', '.join(sorted(df.srcDir.unique()))}",
       f"QSRC threshold(s): {sorted(int(v) for v in df.qsrc.unique())}   CW Stage-2 min/max: "
       f"{sorted(int(v) for v in df.pedcaStage2CwMin.unique())}/{sorted(int(v) for v in df.pedcaStage2CwMax.unique())}   "
       f"load per AC (Mbit/s): {sorted(float(v) for v in df.perAcOfferedLoadMbps.unique() if v > 0)}   "
       f"sim time (s): {sorted(float(v) for v in df.simulationTime.unique())}", ""]

for traffic in sorted(df.trafficModel.unique()):
    t = long[long.trafficModel == traffic]
    ps = sorted(t.psrc.unique()); ads = sorted(t.adoption.unique())
    doc.append(f"## Traffic: {traffic}\n")

    def build(title, ac, m, nd=3, fname=None):
        rows = []
        for ad in ads:
            row = {"adoption %": ad}
            for p in ps:
                row[f"PSRC={p}"] = cell(traffic, p, ad, ac, m, nd)
            rows.append(row)
        tb = pd.DataFrame(rows)
        doc.append(f"### {title}\n"); doc.append(md(tb)); doc.append("")
        tb.to_csv(os.path.join(out, f"table_{traffic}_{fname}.csv"), index=False)

    build("P-EDCA VO: PDR", "AC_VO_PEDCA", "pdr", 3, "vo_pedca_pdr")
    build("P-EDCA VO: throughput (Mbit/s)", "AC_VO_PEDCA", "throughputMbps", 3, "vo_pedca_tput")
    build("P-EDCA VO: p99 delay (ms)", "AC_VO_PEDCA", "p99DelayMs", 2, "vo_pedca_p99")
    build("Legacy VO: PDR", "AC_VO_LEGACY", "pdr", 3, "vo_legacy_pdr")
    build("Legacy VO: p99 delay (ms)", "AC_VO_LEGACY", "p99DelayMs", 2, "vo_legacy_p99")

    # whole VO class pooled (all 20 VO STAs together)
    rows = []
    for ad in ads:
        row = {"adoption %": ad}
        for p in ps:
            s = vo[(vo.trafficModel == traffic) & (vo.psrc == p) & (vo.adoption == ad)].pdr
            row[f"PSRC={p}"] = fmt(s.mean(), s.std()) if len(s) else "–"
        rows.append(row)
    tb = pd.DataFrame(rows)
    doc.append("### All VO stations pooled (legacy + P-EDCA): PDR\n"); doc.append(md(tb)); doc.append("")
    tb.to_csv(os.path.join(out, f"table_{traffic}_vo_all_pdr.csv"), index=False)

    # cost to the other ACs
    for ac in ("AC_VI", "AC_BE", "AC_BK"):
        build(f"{ac}: PDR (effect on other traffic)", ac, "pdr", 3, f"{ac.lower()}_pdr")

    # protocol activity
    rows = []
    for ad in [x for x in ads if x > 0]:
        row = {"adoption %": ad}
        for p in ps:
            ds = cell(traffic, p, ad, "AC_VO_PEDCA", "dsCtsTransmissions", 0)
            rts = cell(traffic, p, ad, "AC_VO_PEDCA", "stage2RtsTransmissions", 0)
            row[f"PSRC={p}  DS-CTS / Stage-2 RTS"] = f"{ds.split(' ')[0]} / {rts.split(' ')[0]}"
        rows.append(row)
    if rows:
        tb = pd.DataFrame(rows)
        doc.append("### P-EDCA activity: DS-CTS / Stage-2 RTS counts\n"); doc.append(md(tb)); doc.append("")
        tb.to_csv(os.path.join(out, f"table_{traffic}_activity.csv"), index=False)

    # total throughput
    rows = []
    for ad in ads:
        row = {"adoption %": ad}
        for p in ps:
            s = tot[(tot.trafficModel == traffic) & (tot.psrc == p) & (tot.adoption == ad)].total
            row[f"PSRC={p}"] = fmt(s.mean(), s.std(), 2) if len(s) else "–"
        rows.append(row)
    tb = pd.DataFrame(rows)
    doc.append("### Total network throughput (Mbit/s, all ACs)\n"); doc.append(md(tb)); doc.append("")
    tb.to_csv(os.path.join(out, f"table_{traffic}_total_tput.csv"), index=False)

text = "\n".join(doc)
open(os.path.join(out, "tables.md"), "w").write(text)
print(text)
print(f"\nWrote tables to: {out}")
