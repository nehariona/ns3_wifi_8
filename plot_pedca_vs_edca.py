#!/usr/bin/env python3
"""
PEDCA vs EDCA comparison plots for every (qsrc, psrc) pair.

Reads the ns-3 sweep summary CSV and, for each qsrc/psrc combination, makes one
figure: 5 metric rows (mean delay, P95, P99, PDR, throughput) x one column per
traffic model, with adoption % on the x-axis.

Usage:
    python3 plot_pedca_vs_edca.py                 # uses the default CSV path below
    python3 plot_pedca_vs_edca.py path/to/file.csv
    python3 plot_pedca_vs_edca.py file.csv -o out_dir

Requires: pandas, matplotlib   (pip install pandas matplotlib)
"""
import argparse
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
from matplotlib.backends.backend_pdf import PdfPages

DEFAULT_CSV = "/Users/neharionaalice/Downloads/ns-3.48/results/qp_sweep/summary_qsrc_psrc.csv"

METRICS = [
    ("meanDelayMs", "Mean delay (ms)"),
    ("p95DelayMs", "P95 delay (ms)"),
    ("p99DelayMs", "P99 delay (ms)"),
    ("pdr", "PDR"),
    ("throughputMbps", "Throughput (Mbps)"),
]

# ac name in CSV -> (legend label, colour, marker)
SERIES = {
    "AC_VO_LEGACY": ("EDCA (legacy VO)", "tab:blue", "o"),
    "AC_VO_PEDCA": ("PEDCA (VO)", "tab:red", "s"),
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="?", default=DEFAULT_CSV, help="summary_qsrc_psrc.csv path")
    ap.add_argument("-o", "--outdir", default=None,
                    help="output folder (default: <csv folder>/pedca_vs_edca_plots)")
    args = ap.parse_args()

    csv_path = Path(args.csv).expanduser()
    if not csv_path.is_file():
        sys.exit(f"CSV not found: {csv_path}")
    outdir = Path(args.outdir).expanduser() if args.outdir else csv_path.parent / "pedca_vs_edca_plots"
    outdir.mkdir(parents=True, exist_ok=True)

    df = pd.read_csv(csv_path)
    df = df[df["ac"].isin(SERIES)]
    models = list(dict.fromkeys(df["trafficModel"]))  # keep CSV order

    with PdfPages(outdir / "all_qsrc_psrc.pdf") as pdf:
        for q in sorted(df["qsrc"].unique()):
            for p in sorted(df["psrc"].unique()):
                sub = df[(df.qsrc == q) & (df.psrc == p)]
                if sub.empty:
                    continue
                fig, axes = plt.subplots(len(METRICS), len(models),
                                         figsize=(4.3 * len(models), 3 * len(METRICS)),
                                         sharex=True, squeeze=False)
                for i, (col, label) in enumerate(METRICS):
                    for j, tm in enumerate(models):
                        ax = axes[i, j]
                        for ac, (name, colour, marker) in SERIES.items():
                            d = sub[(sub.trafficModel == tm) & (sub.ac == ac)].sort_values("adoptionPct")
                            d = d[d["throughputMbps"] > 0]  # drop points where this class carries no traffic
                            ax.plot(d["adoptionPct"], d[col], color=colour, marker=marker, label=name)
                        ax.grid(alpha=0.3)
                        if i == 0:
                            ax.set_title(tm, fontsize=12, fontweight="bold")
                        if j == 0:
                            ax.set_ylabel(label)
                        if i == len(METRICS) - 1:
                            ax.set_xlabel("PEDCA adoption (%)")
                        ax.set_xticks(sorted(df["adoptionPct"].unique()))
                handles, labels = axes[0, 0].get_legend_handles_labels()
                fig.legend(handles, labels, loc="upper right", ncol=2)
                fig.suptitle(f"PEDCA vs EDCA  |  QSRC = {q}, PSRC = {p}", fontsize=15, y=0.995, x=0.4)
                fig.tight_layout(rect=[0, 0, 1, 0.98])
                fig.savefig(outdir / f"qsrc{q}_psrc{p}.png", dpi=130)
                pdf.savefig(fig)
                plt.close(fig)
                print(f"saved qsrc{q}_psrc{p}.png")

    print(f"\nDone. Output in: {outdir}")


if __name__ == "__main__":
    main()
