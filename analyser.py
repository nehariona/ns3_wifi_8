#!/usr/bin/env python3
"""
analyser.py
===========
Summarise the CSV written by run_pedca_adoption.sh (default results/pedca_ratio.csv)
to show how the results change with the P-EDCA adoption ratio.

Tables printed (one block per traffic model / QSRC / PSRC / payload / station-count
combination found in the file; mean +/- 95% CI over RngRun replicates when there is
more than one):
  - AC_VO combined, legacy sub-group and P-EDCA sub-group: throughput, per-STA
    throughput, PDR, mean / p99 delay, MAC retransmission ratio
  - collateral effect on AC_VI / AC_BE / AC_BK
  - change relative to the lowest adoption level (normally 0 % = pure EDCA)
  - P-EDCA STA vs legacy STA inside the same BSS
  - P-EDCA activity (DS-CTS and Stage-2 RTS per P-EDCA STA)
  - channel and overhead check: total goodput, delivered packets/s, airtime per
    delivered packet, DS-CTS per data attempt, share of DS-CTS windows that were
    followed by no Stage-2 RTS

It also writes adoption_summary.csv and one PNG per configuration to --outdir.

Usage
-----
  python3 analyser.py
  python3 analyser.py results/pedca_ratio.csv --outdir results --no-plots

Requires: python3, pandas, numpy (matplotlib optional, for the plots).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

VO_LEGACY, VO_PEDCA, VO_ALL = "AC_VO_LEGACY", "AC_VO_PEDCA", "AC_VO_ALL"
OTHER_ACS = ["AC_VI", "AC_BE", "AC_BK"]

# one block of output per distinct value of these columns
CONFIG_COLS = ["trafficModel", "pedcaQsrcThreshold", "pedcaPsrcThreshold",
               "payloadSize", "numStations"]
RUN_COLS = CONFIG_COLS + ["adoption", "rngSeed", "rngRun"]

METRICS = ["throughputMbps", "perStaThroughputMbps", "pdr_pct", "meanDelayMs",
           "meanJitterMs", "p95DelayMs", "p99DelayMs", "retryRatio",
           "dsCtsPerSta", "rtsPerSta"]

REQUIRED = set(CONFIG_COLS) | {
    "ac", "pedcaAdoptionRatio", "stationsInAc", "rngSeed", "rngRun", "simulationTime",
    "throughputMbps", "payloadGoodputMbps", "txPackets", "rxPackets", "meanDelayMs",
    "meanJitterMs", "p95DelayMs", "p99DelayMs", "macDataAttempts", "macRetransmissions",
    "dsCtsTransmissions", "stage2RtsTransmissions"}

# two-sided 95% Student-t critical values by degrees of freedom (nearest lower key)
T975 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
        8: 2.306, 9: 2.262, 10: 2.228, 15: 2.131, 20: 2.086, 30: 2.042}


def t_crit(n: int) -> float:
    dof = n - 1
    if dof < 1:
        return float("nan")
    for k in sorted(T975, reverse=True):
        if dof >= k:
            return T975[k]
    return T975[1]


# ---------------------------------------------------------------------------
# Data preparation
# ---------------------------------------------------------------------------

def load(path: Path) -> pd.DataFrame:
    if not path.exists() or path.stat().st_size == 0:
        sys.exit(f"No results in {path}")
    df = pd.read_csv(path)
    missing = REQUIRED - set(df.columns)
    if missing:
        sys.exit(f"{path} is missing columns: {sorted(missing)}")
    df["adoption"] = (df["pedcaAdoptionRatio"] * 100).round().astype(int)
    return df


def channel_table(raw: pd.DataFrame) -> pd.DataFrame:
    """Per-run channel / overhead figures, from the five original AC rows."""
    rows = []
    for k, g in raw.groupby(RUN_COLS):
        T = g["simulationTime"].iloc[0]
        rx = g["rxPackets"].sum()
        ds = g["dsCtsTransmissions"].sum()
        rts = g["stage2RtsTransmissions"].sum()
        att = g["macDataAttempts"].sum()
        rows.append({
            **dict(zip(RUN_COLS, k)),
            "goodputMbps": g["payloadGoodputMbps"].sum(),
            "lowAcGoodputMbps": g.loc[g["ac"].isin(["AC_BE", "AC_BK"]), "payloadGoodputMbps"].sum(),
            "rxPps": rx / T,
            "usPerPkt": T * 1e6 / rx if rx else np.nan,
            "dsCts": ds,
            "stage2Rts": rts,
            "dsCtsPerAttemptPct": 100.0 * ds / att if att else np.nan,
            "noRtsPct": 100.0 * (ds - rts) / ds if ds else np.nan,
        })
    out = pd.DataFrame(rows)
    return out.groupby(CONFIG_COLS + ["adoption"], as_index=False).mean(numeric_only=True)


def prepare(raw: pd.DataFrame) -> pd.DataFrame:
    df = raw.copy()

    # Combined AC_VO row (legacy + P-EDCA sub-groups share one real AC_VO)
    comb = []
    vo = df[df["ac"].isin([VO_LEGACY, VO_PEDCA])]
    for k, g in vo.groupby(RUN_COLS):
        rx, tx = g["rxPackets"].sum(), g["txPackets"].sum()
        comb.append({
            **dict(zip(RUN_COLS, k)), "ac": VO_ALL,
            "stationsInAc": g["stationsInAc"].sum(),
            "throughputMbps": g["throughputMbps"].sum(),
            "payloadGoodputMbps": g["payloadGoodputMbps"].sum(),
            "txPackets": tx, "rxPackets": rx,
            "meanDelayMs": (g["meanDelayMs"].fillna(0) * g["rxPackets"]).sum() / rx if rx > 0 else np.nan,
            "macDataAttempts": g["macDataAttempts"].sum(),
            "macRetransmissions": g["macRetransmissions"].sum(),
            "dsCtsTransmissions": g["dsCtsTransmissions"].sum(),
            "stage2RtsTransmissions": g["stage2RtsTransmissions"].sum(),
        })
    df = pd.concat([df, pd.DataFrame(comb)], ignore_index=True)
    df = df[df["stationsInAc"] > 0].copy()  # drops the empty sub-group at 0 % / 100 %

    df["pdr_pct"] = np.where(df["txPackets"] > 0, 100.0 * df["rxPackets"] / df["txPackets"], np.nan)
    df["retryRatio"] = np.where(df["macDataAttempts"] > 0,
                                df["macRetransmissions"] / df["macDataAttempts"], np.nan)
    df["perStaThroughputMbps"] = df["throughputMbps"] / df["stationsInAc"]
    df["dsCtsPerSta"] = df["dsCtsTransmissions"] / df["stationsInAc"]
    df["rtsPerSta"] = df["stage2RtsTransmissions"] / df["stationsInAc"]
    return df


def aggregate(df: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for k, g in df.groupby(CONFIG_COLS + ["adoption", "ac"]):
        row = {**dict(zip(CONFIG_COLS + ["adoption", "ac"], k)), "n": g["rngRun"].nunique()}
        for m in METRICS:
            v = g[m].dropna()
            n = len(v)
            row[m] = v.mean() if n else np.nan
            row[m + "_ci"] = t_crit(n) * v.std(ddof=1) / np.sqrt(n) if n > 1 else np.nan
        rows.append(row)
    return pd.DataFrame(rows)


# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

def cell(r, m: str) -> str:
    v, ci = r.get(m), r.get(m + "_ci")
    if v is None or pd.isna(v):
        return "-"
    return f"{v:.3f}" if ci is None or pd.isna(ci) else f"{v:.3f}±{ci:.3f}"


def table(g: pd.DataFrame, acs, cols) -> pd.DataFrame:
    rows = []
    for ac in acs:
        for ad in sorted(g["adoption"].unique()):
            r = g[(g["ac"] == ac) & (g["adoption"] == ad)]
            if r.empty:
                continue
            r = r.iloc[0]
            rows.append({"AC": ac, "adopt%": ad, "n": int(r["n"]),
                         **{short: cell(r, m) for m, short in cols}})
    return pd.DataFrame(rows)


def cfg_title(cfg) -> str:
    tm, q, p, payload, n = cfg
    return f"{tm}  |  QSRC={q} PSRC={p}  |  payload {payload} B  |  {n} STAs"


def print_report(agg: pd.DataFrame, chan: pd.DataFrame) -> None:
    pd.set_option("display.width", 250)
    pd.set_option("display.max_columns", 50)
    main_cols = [("throughputMbps", "thr[Mbps]"), ("perStaThroughputMbps", "thr/STA"),
                 ("pdr_pct", "PDR[%]"), ("meanDelayMs", "delay[ms]"),
                 ("p99DelayMs", "p99[ms]"), ("retryRatio", "retry")]
    for cfg, g in agg.groupby(CONFIG_COLS):
        print("\n" + "=" * 110)
        print(cfg_title(cfg))
        print("mean ± 95% CI over RngRun replicates (n = replicates; no CI when n = 1)")
        print("=" * 110)

        print("\nAC_VO by adoption ratio (the combined row has no p99: percentiles cannot be merged)")
        print(table(g, [VO_ALL, VO_LEGACY, VO_PEDCA], main_cols).to_string(index=False))

        print("\nCollateral effect on the other ACs")
        print(table(g, OTHER_ACS, main_cols).to_string(index=False))

        base_ad = g["adoption"].min()
        print(f"\nChange relative to {base_ad}% adoption (means, %)")
        rel = []
        for ac in [VO_ALL] + OTHER_ACS:
            b = g[(g["ac"] == ac) & (g["adoption"] == base_ad)]
            if b.empty:
                continue
            b = b.iloc[0]
            for ad in sorted(g["adoption"].unique()):
                if ad == base_ad:
                    continue
                r = g[(g["ac"] == ac) & (g["adoption"] == ad)]
                if r.empty:
                    continue
                r = r.iloc[0]
                row = {"AC": ac, "adopt%": ad}
                for m, short in [("throughputMbps", "d thr"), ("meanDelayMs", "d delay"), ("pdr_pct", "d PDR")]:
                    ok = b[m] and not pd.isna(b[m]) and not pd.isna(r[m])
                    row[short] = f"{100.0 * (r[m] - b[m]) / b[m]:+.1f}" if ok else "-"
                rel.append(row)
        print(pd.DataFrame(rel).to_string(index=False) if rel else "(no baseline)")

        print("\nP-EDCA STA vs legacy STA inside the same BSS (ratio P-EDCA / legacy, means)")
        fair = []
        for ad in sorted(g["adoption"].unique()):
            lg = g[(g["ac"] == VO_LEGACY) & (g["adoption"] == ad)]
            pe = g[(g["ac"] == VO_PEDCA) & (g["adoption"] == ad)]
            if lg.empty or pe.empty:
                continue
            lg, pe = lg.iloc[0], pe.iloc[0]
            row = {"adopt%": ad}
            for m, short in [("perStaThroughputMbps", "thr/STA"), ("meanDelayMs", "delay"),
                             ("p99DelayMs", "p99"), ("retryRatio", "retry")]:
                ok = lg[m] and not pd.isna(lg[m]) and not pd.isna(pe[m])
                row[short] = f"{pe[m] / lg[m]:.2f}" if ok else "-"
            fair.append(row)
        print(pd.DataFrame(fair).to_string(index=False) if fair else "(needs a mixed-adoption point)")

        print("\nP-EDCA activity (per P-EDCA STA over the run)")
        act = table(g, [VO_PEDCA], [("dsCtsPerSta", "DS-CTS/STA"), ("rtsPerSta", "Stage2-RTS/STA")])
        print(act.to_string(index=False) if not act.empty else "(no P-EDCA STAs)")

        c = chan.copy()
        for col, val in zip(CONFIG_COLS, cfg):
            c = c[c[col] == val]
        c = c.sort_values("adoption")
        print("\nChannel and overhead check (a saturated channel hides any P-EDCA benefit)")
        show = pd.DataFrame({
            "adopt%": c["adoption"],
            "goodput[Mbps]": c["goodputMbps"].round(2),
            "BE+BK[Mbps]": c["lowAcGoodputMbps"].round(2),
            "rx pkt/s": c["rxPps"].round(0),
            "us/pkt": c["usPerPkt"].round(0),
            "DS-CTS": c["dsCts"].round(0),
            "Stage2-RTS": c["stage2Rts"].round(0),
            "DS-CTS/attempt[%]": c["dsCtsPerAttemptPct"].round(1),
            "DS-CTS w/o RTS[%]": c["noRtsPct"].round(1),
        })
        print(show.to_string(index=False))


# ---------------------------------------------------------------------------
# Plots
# ---------------------------------------------------------------------------

def make_plots(agg: pd.DataFrame, outdir: Path) -> None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed - skipping plots")
        return
    panels = [
        ("meanDelayMs", "AC_VO mean delay (ms)", [VO_ALL, VO_LEGACY, VO_PEDCA], True),
        ("p99DelayMs", "AC_VO p99 delay (ms)", [VO_LEGACY, VO_PEDCA], True),
        ("pdr_pct", "PDR (%)", [VO_ALL, VO_LEGACY, VO_PEDCA], False),
        ("retryRatio", "MAC retransmission ratio", [VO_ALL, VO_LEGACY, VO_PEDCA], False),
        ("perStaThroughputMbps", "Per-STA throughput (Mbps)", [VO_LEGACY, VO_PEDCA], False),
        ("throughputMbps", "Other ACs throughput (Mbps)", OTHER_ACS, False),
    ]
    for cfg, g in agg.groupby(CONFIG_COLS):
        fig, axes = plt.subplots(2, 3, figsize=(16, 9))
        for ax, (m, title, acs, logy) in zip(axes.ravel(), panels):
            plotted = False
            for ac in acs:
                s = g[g["ac"] == ac].sort_values("adoption")
                s = s[s[m].notna()]
                if s.empty:
                    continue
                ax.errorbar(s["adoption"], s[m], yerr=np.nan_to_num(s[m + "_ci"].to_numpy()),
                            marker="o", capsize=3, label=ac)
                plotted = True
            if plotted and logy and (g[g["ac"].isin(acs)][m].dropna() > 0).all():
                ax.set_yscale("log")
            ax.set_title(title)
            ax.set_xlabel("P-EDCA adoption among AC_VO STAs (%)")
            ax.set_xticks(sorted(g["adoption"].unique()))
            ax.grid(alpha=0.3)
            if plotted:
                ax.legend(fontsize=8)
        fig.suptitle(f"P-EDCA adoption sweep - {cfg_title(cfg)}")
        fig.tight_layout()
        tm, q, p = cfg[0], cfg[1], cfg[2]
        path = outdir / f"adoption_{tm}_q{q}_p{p}.png"
        fig.savefig(path, dpi=130)
        plt.close(fig)
        print(f"plot written: {path}")


# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("Usage")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="?", default="results/pedca_ratio.csv",
                    help="CSV written by run_pedca_adoption.sh")
    ap.add_argument("--outdir", default=None, help="where to write the summary CSV and plots "
                    "(default: the folder of the input CSV)")
    ap.add_argument("--no-plots", action="store_true")
    a = ap.parse_args()

    path = Path(a.csv).expanduser()
    outdir = Path(a.outdir).expanduser() if a.outdir else path.parent
    outdir.mkdir(parents=True, exist_ok=True)

    raw = load(path)
    chan = channel_table(raw)
    agg = aggregate(prepare(raw))
    agg.to_csv(outdir / "adoption_summary.csv", index=False)
    print_report(agg, chan)
    if not a.no_plots:
        make_plots(agg, outdir)
    print(f"\nsummary: {outdir / 'adoption_summary.csv'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
