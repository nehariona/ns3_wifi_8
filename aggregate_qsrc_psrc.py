#!/usr/bin/env python3
"""Aggregate the QSRC x PSRC sweep.

Reads every raw CSV under <root>/*/<traffic>/raw/*.csv (the thresholds are taken from the
pedcaQsrcThreshold / pedcaPsrcThreshold columns of each CSV), averages over replicates and
writes:
  <root>/summary_qsrc_psrc.csv        one row per (traffic, adoption, QSRC, PSRC, AC)
  <root>/pivot_<metric>.csv           QSRC x PSRC tables for the P-EDCA VO class
The 0 % baseline (run once) is copied into every (QSRC, PSRC) pair so tables are complete.
"""
import glob, os, sys
import pandas as pd

root = sys.argv[1] if len(sys.argv) > 1 else "results/qp_sweep"
files = sorted(glob.glob(os.path.join(root, "*", "*", "raw", "*.csv")))
if not files:
    sys.exit(f"No raw CSV files under {root}/*/*/raw/")

frames = []
for f in files:
    try:
        d = pd.read_csv(f)
    except Exception as e:
        print("skip", f, e); continue
    d["combo"] = f.split(os.sep)[-4]
    d["replicate"] = os.path.splitext(os.path.basename(f))[0].rsplit("run", 1)[-1]
    frames.append(d)
df = pd.concat(frames, ignore_index=True)
df["adoptionPct"] = (100 * df["nVoPedca"] / (df["nVoPedca"] + df["nVoLegacy"])).round().astype(int)
df = df.rename(columns={"pedcaQsrcThreshold": "qsrc", "pedcaPsrcThreshold": "psrc"})

# copy the baseline (0 %) into every (qsrc, psrc) pair found
pairs = sorted(set(map(tuple, df.loc[df.combo != "baseline_0pct", ["qsrc", "psrc"]].values)))
base = df[df.combo == "baseline_0pct"]
rest = df[df.combo != "baseline_0pct"]
copies = []
for q, p in pairs:
    b = base.copy(); b["qsrc"], b["psrc"] = q, p; copies.append(b)
df = pd.concat([rest] + copies, ignore_index=True)

metrics = [c for c in ["throughputMbps", "pdr", "meanDelayMs", "p95DelayMs", "p99DelayMs",
                       "p999DelayMs", "macRetransmissions", "dsCtsTransmissions",
                       "stage2RtsTransmissions"] if c in df.columns]
keys = ["trafficModel", "adoptionPct", "qsrc", "psrc", "ac"]
g = df.groupby(keys)
summary = g[metrics].mean().round(4)
summary["replicates"] = g.size()
summary = summary.reset_index()
out = os.path.join(root, "summary_qsrc_psrc.csv")
summary.to_csv(out, index=False)
print("Wrote", out, f"({len(summary)} rows)")

# QSRC x PSRC tables for the P-EDCA VO class, at the highest adoption level present
vo = summary[summary.ac == "AC_VO_PEDCA"]
for traffic, t in vo.groupby("trafficModel"):
    top = t[t.adoptionPct == t.adoptionPct.max()]
    for m in ("pdr", "p99DelayMs", "throughputMbps"):
        if m in top.columns:
            pv = top.pivot(index="qsrc", columns="psrc", values=m)
            path = os.path.join(root, f"pivot_{traffic}_{m}.csv"); pv.to_csv(path)
            print(f"\n{traffic}  AC_VO_PEDCA  {m}  (adoption {int(top.adoptionPct.max())} %) rows=QSRC cols=PSRC")
            print(pv.round(3).to_string())
