#!/usr/bin/env python3
"""
pedca_adoption_sweep.py
=======================
Run Exp 1 of the P-EDCA vs EDCA plan (P-EDCA adoption sweep) and show how the
results change with the adoption ratio.

What it does
------------
1. For every  traffic model x adoption level x seed  it launches
   pedca-360mhz once. Each run writes its own CSV (raw/), so runs can
   execute in parallel and the sweep can be resumed (finished runs are skipped).
2. Merges the per-run CSVs into exp1_all_runs.csv.
3. Aggregates over seeds (mean +/- 95% CI) and prints tables:
     - VO (combined, legacy sub-group, P-EDCA sub-group): throughput, per-STA
       throughput, PDR, mean / p99 delay, MAC retransmission ratio
     - collateral effect on AC_VI / AC_BE / AC_BK
     - change relative to the 0% (pure EDCA) baseline
     - P-EDCA STA vs legacy STA in the same BSS (fairness)
     - P-EDCA activity (DS-CTS and Stage-2 RTS per P-EDCA STA)
4. Saves exp1_summary.csv and one PNG per traffic model.

Adoption is a fraction of the AC_VO stations (plan summary: 0,25,50,75,100% of
20 VO STAs = 0,5,10,15,20 STAs). AC_VI / AC_BE / AC_BK stay legacy EDCA.
Seeds are realised as RngRun = 1..N with a fixed RngSeed.

Usage
-----
  python3 pedca_adoption_sweep.py --ns3-dir ~/ns-3.48
  python3 pedca_adoption_sweep.py --ns3-dir ~/ns-3.48 --seeds 5 --jobs 4
  python3 pedca_adoption_sweep.py --ns3-dir ~/ns-3.48 --traffic poissonBurst --seeds 1
  python3 pedca_adoption_sweep.py --analyze-only --outdir results/exp1
  python3 pedca_adoption_sweep.py --dry-run

Requires: python3, pandas, numpy (matplotlib optional, for the plots).
The scenario must be built as scratch/pedca-360mhz (see --program).
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

VO_LEGACY, VO_PEDCA, VO_ALL = "AC_VO_LEGACY", "AC_VO_PEDCA", "AC_VO_ALL"
OTHER_ACS = ["AC_VI", "AC_BE", "AC_BK"]

# two-sided 95% Student-t critical values by degrees of freedom (nearest lower key)
T975 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
        8: 2.306, 9: 2.262, 10: 2.228, 15: 2.131, 20: 2.086, 30: 2.042}

METRICS = ["throughputMbps", "perStaThroughputMbps", "pdr_pct", "meanDelayMs",
           "meanJitterMs", "p95DelayMs", "p99DelayMs", "retryRatio",
           "dsCtsPerSta", "rtsPerSta"]


def t_crit(n: int) -> float:
    dof = n - 1
    if dof < 1:
        return float("nan")
    for k in sorted(T975, reverse=True):
        if dof >= k:
            return T975[k]
    return T975[1]


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

def csv_ok(path: Path) -> bool:
    """A finished run has a header plus 5 AC rows."""
    if not path.exists() or path.stat().st_size == 0:
        return False
    with open(path) as f:
        return sum(1 for _ in f) >= 6


def build_jobs(a, raw: Path, logs: Path):
    extra = shlex.split(a.extra)
    jobs = []
    for tm in a.traffic:
        for ad in a.adoption:
            exact = a.n_vo * ad / 100.0
            n_pedca = int(round(exact))
            if abs(exact - n_pedca) > 1e-9:
                print(f"WARNING: {ad}% of {a.n_vo} VO STAs is not an integer; using {n_pedca}")
            n_leg = a.n_vo - n_pedca
            label = f"exp1-{tm}-a{ad:03d}"
            for seed in range(1, a.seeds + 1):
                stem = f"{label}-run{seed}"
                sim_args = [
                    f"--nBe={a.n_be}", f"--nBk={a.n_bk}", f"--nVi={a.n_vi}",
                    f"--nVoLegacy={n_leg}", f"--nVoPedca={n_pedca}",
                    f"--perAcLoadMbps={a.load_per_ac}",
                    f"--trafficModel={tm}",
                    f"--scenarioLabel={label}",
                    f"--rngSeed={a.rng_seed}", f"--rngRun={seed}",
                    f"--outputCsv={raw / (stem + '.csv')}",
                ] + extra
                jobs.append((stem, raw / (stem + ".csv"), logs / (stem + ".log"), sim_args))
    return jobs


def run_one(job, ns3_dir: Path, program: str, timeout: int):
    stem, csv_path, log_path, sim_args = job
    if csv_ok(csv_path):
        return stem, "skipped (already done)", 0.0
    if csv_path.exists():
        csv_path.unlink()
    cmd = ["./ns3", "run", "--no-build", f"{program} {shlex.join(sim_args)}"]
    t0 = time.time()
    try:
        with open(log_path, "w") as log:
            rc = subprocess.run(cmd, cwd=ns3_dir, stdout=log, stderr=subprocess.STDOUT,
                                timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        return stem, "TIMEOUT", time.time() - t0
    except FileNotFoundError:
        return stem, f"FAILED (no ./ns3 in {ns3_dir})", 0.0
    ok = rc == 0 and csv_ok(csv_path)
    return stem, ("ok" if ok else f"FAILED (exit code {rc}, see {log_path.name})"), time.time() - t0


def run_all(a, raw: Path, logs: Path) -> bool:
    ns3_dir = Path(a.ns3_dir).expanduser().resolve()
    jobs = build_jobs(a, raw, logs)
    if a.dry_run:
        for stem, _, _, sim_args in jobs:
            print(f"./ns3 run --no-build \"{a.program} {shlex.join(sim_args)}\"")
        print(f"\n{len(jobs)} runs (dry run, nothing executed)")
        return False
    if not a.skip_build:
        print("Building ns-3 once (use --skip-build to skip) ...")
        rc = subprocess.run(["./ns3", "build"], cwd=ns3_dir).returncode
        if rc != 0:
            sys.exit("ns-3 build failed")
    print(f"{len(jobs)} runs, {a.jobs} in parallel")
    failures = []
    done = 0
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = [ex.submit(run_one, j, ns3_dir, a.program, a.timeout) for j in jobs]
        for fut in cf.as_completed(futs):
            stem, status, secs = fut.result()
            done += 1
            print(f"[{done}/{len(jobs)}] {stem}: {status} ({secs:.0f} s)", flush=True)
            if status.startswith(("FAILED", "TIMEOUT")):
                failures.append((stem, status))
    if failures:
        print("\nFailed runs:")
        for stem, status in failures:
            print(f"  {stem}: {status}")
    return True


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

def load_runs(raw: Path) -> pd.DataFrame:
    frames = [pd.read_csv(f) for f in sorted(raw.glob("*.csv")) if f.stat().st_size > 0]
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()


def prepare(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["adoption"] = (df["pedcaAdoptionRatio"] * 100).round().astype(int)
    key = ["trafficModel", "adoption", "rngSeed", "rngRun"]

    # Combined AC_VO row (legacy + P-EDCA sub-groups share one real AC_VO)
    comb = []
    vo = df[df["ac"].isin([VO_LEGACY, VO_PEDCA])]
    for k, g in vo.groupby(key):
        rx, tx = g["rxPackets"].sum(), g["txPackets"].sum()
        comb.append({
            **dict(zip(key, k)), "ac": VO_ALL,
            "stationsInAc": g["stationsInAc"].sum(),
            "throughputMbps": g["throughputMbps"].sum(),
            "txPackets": tx, "rxPackets": rx,
            "meanDelayMs": (g["meanDelayMs"].fillna(0) * g["rxPackets"]).sum() / rx if rx > 0 else np.nan,
            "macDataAttempts": g["macDataAttempts"].sum(),
            "macRetransmissions": g["macRetransmissions"].sum(),
            "dsCtsTransmissions": g["dsCtsTransmissions"].sum(),
            "stage2RtsTransmissions": g["stage2RtsTransmissions"].sum(),
        })
    df = pd.concat([df, pd.DataFrame(comb)], ignore_index=True)
    df = df[df["stationsInAc"] > 0].copy()  # drops the empty sub-group at 0% / 100%

    df["pdr_pct"] = np.where(df["txPackets"] > 0, 100.0 * df["rxPackets"] / df["txPackets"], np.nan)
    df["retryRatio"] = np.where(df["macDataAttempts"] > 0,
                                df["macRetransmissions"] / df["macDataAttempts"], np.nan)
    df["perStaThroughputMbps"] = df["throughputMbps"] / df["stationsInAc"]
    df["dsCtsPerSta"] = df["dsCtsTransmissions"] / df["stationsInAc"]
    df["rtsPerSta"] = df["stage2RtsTransmissions"] / df["stationsInAc"]
    return df


def aggregate(df: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for (tm, ad, ac), g in df.groupby(["trafficModel", "adoption", "ac"]):
        row = {"trafficModel": tm, "adoption": ad, "ac": ac, "n": g["rngRun"].nunique()}
        for m in METRICS:
            v = g[m].dropna()
            n = len(v)
            row[m] = v.mean() if n else np.nan
            row[m + "_ci"] = t_crit(n) * v.std(ddof=1) / np.sqrt(n) if n > 1 else np.nan
        rows.append(row)
    return pd.DataFrame(rows)


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


def print_report(a: pd.DataFrame) -> None:
    pd.set_option("display.width", 250)
    pd.set_option("display.max_columns", 50)
    main_cols = [("throughputMbps", "thr[Mbps]"), ("perStaThroughputMbps", "thr/STA"),
                 ("pdr_pct", "PDR[%]"), ("meanDelayMs", "delay[ms]"),
                 ("p99DelayMs", "p99[ms]"), ("retryRatio", "retry")]
    for tm, g in a.groupby("trafficModel"):
        print("\n" + "=" * 110)
        print(f"Traffic model: {tm}     (mean ± 95% CI over seeds; n = seeds)")
        print("=" * 110)

        print("\nAC_VO by adoption ratio")
        print(table(g, [VO_ALL, VO_LEGACY, VO_PEDCA], main_cols).to_string(index=False))

        print("\nCollateral effect on the legacy ACs")
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
                    row[short] = f"{100.0 * (r[m] - b[m]) / b[m]:+.1f}" if b[m] and not pd.isna(b[m]) and not pd.isna(r[m]) else "-"
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
                row[short] = f"{pe[m] / lg[m]:.2f}" if lg[m] and not pd.isna(lg[m]) and not pd.isna(pe[m]) else "-"
            fair.append(row)
        print(pd.DataFrame(fair).to_string(index=False) if fair else "(needs a mixed-adoption point)")

        print("\nP-EDCA activity (per P-EDCA STA over the run)")
        act = table(g, [VO_PEDCA], [("dsCtsPerSta", "DS-CTS/STA"), ("rtsPerSta", "Stage2-RTS/STA")])
        print(act.to_string(index=False) if not act.empty else "(no P-EDCA STAs)")


def make_plots(a: pd.DataFrame, outdir: Path) -> None:
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
        ("throughputMbps", "Legacy ACs throughput (Mbps)", OTHER_ACS, False),
    ]
    for tm, g in a.groupby("trafficModel"):
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
        fig.suptitle(f"P-EDCA adoption sweep - {tm} (mean ± 95% CI)")
        fig.tight_layout()
        path = outdir / f"exp1_{tm}.png"
        fig.savefig(path, dpi=130)
        plt.close(fig)
        print(f"plot written: {path}")


# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description=__doc__.split("Usage")[0],
                                formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("--ns3-dir", default=".", help="ns-3 top-level directory (contains ./ns3)")
    p.add_argument("--program", default="scratch/pedca-360mhz",
                   help="ns-3 program as passed to './ns3 run'")
    p.add_argument("--outdir", default="results/exp1")
    p.add_argument("--seeds", type=int, default=5)
    p.add_argument("--rng-seed", type=int, default=1)
    p.add_argument("--traffic", nargs="+", default=["cbr", "poisson", "poissonBurst"],
                   choices=["cbr", "poisson", "poissonBurst"])
    p.add_argument("--adoption", nargs="+", type=int, default=[0, 25, 50, 75, 100],
                   help="percent of AC_VO stations running P-EDCA")
    p.add_argument("--n-vo", type=int, default=20)
    p.add_argument("--n-vi", type=int, default=4)
    p.add_argument("--n-be", type=int, default=4)
    p.add_argument("--n-bk", type=int, default=4)
    p.add_argument("--load-per-ac", type=float, default=12.0, help="Mbps per AC")
    p.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    p.add_argument("--timeout", type=int, default=7200, help="seconds per run")
    p.add_argument("--extra", default="",
                   help='extra scenario arguments, e.g. "--simulationTime=30 --dataMode=EhtMcs7"')
    p.add_argument("--skip-build", action="store_true")
    p.add_argument("--analyze-only", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-plots", action="store_true")
    return p.parse_args()


def main() -> int:
    a = parse_args()
    outdir = Path(a.outdir).expanduser().resolve()
    raw, logs = outdir / "raw", outdir / "logs"
    raw.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)

    if not a.analyze_only:
        ran = run_all(a, raw, logs)
        if a.dry_run or not ran:
            return 0

    df = load_runs(raw)
    if df.empty:
        print(f"No results found in {raw}")
        return 1
    df.to_csv(outdir / "exp1_all_runs.csv", index=False)
    df = prepare(df)
    agg = aggregate(df)
    agg.to_csv(outdir / "exp1_summary.csv", index=False)
    print_report(agg)
    if not a.no_plots:
        make_plots(agg, outdir)
    print(f"\nmerged runs: {outdir / 'exp1_all_runs.csv'}\nsummary:     {outdir / 'exp1_summary.csv'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

