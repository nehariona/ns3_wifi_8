#!/usr/bin/env bash
# EDCA vs P-EDCA comparison driver for the ns-3.48 P-EDCA adoption-ratio scenario.
#
# Defaults: EDCA baseline (0 of 16 VO STAs on P-EDCA) vs full P-EDCA (16 of 16),
# 3 per-AC loads, 5 seeds, runs in parallel, merges everything into one CSV.
#
# Examples
#   ./run_pedca_compare.sh                                  # default compare
#   LOADS="6 8 10 12" SEEDS=10 ./run_pedca_compare.sh       # custom loads / seeds
#   ADOPT="0 4 8 12 16" ./run_pedca_compare.sh              # full adoption sweep
#   ADOPT="0" LOADS="2 4 6 8 10 12 14" SEEDS=1 ./run_pedca_compare.sh   # load calibration (EDCA only)
#   EXTRA="--staStreams=2 --dataMcs=9" ./run_pedca_compare.sh           # extra scenario args
#
# Env vars (all optional)
#   NS3_DIR    ns-3 root                       (default: $HOME/ns-3.48)
#   SCENARIO   scratch program name            (default: scratch/pedca-ratio-validation)
#   TOTAL_VO   total AC_VO stations, held fixed (default: 16)
#   ADOPT      list of nVoPedca values         (default: "0 16")
#   LOADS      list of per-AC loads in Mbit/s  (default: "6 8 10")
#   SEEDS      number of RngRun values (1..N)  (default: 5)
#   JOBS       parallel jobs                   (default: nproc)
#   OUT        output directory                (default: ./results/pedca_compare_<timestamp>)
#   EXTRA      extra args passed to the scenario

set -euo pipefail

NS3_DIR=${NS3_DIR:-$HOME/ns-3.48}
SCENARIO=${SCENARIO:-scratch/pedca-ratio-validation}
TOTAL_VO=${TOTAL_VO:-16}
ADOPT=${ADOPT:-"0 16"}
LOADS=${LOADS:-"6 8 10"}
SEEDS=${SEEDS:-5}
JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}
EXTRA=${EXTRA:-}
STAMP=$(date +%Y%m%d_%H%M%S)
OUT=${OUT:-$PWD/results/pedca_compare_$STAMP}

mkdir -p "$OUT/raw" "$OUT/logs"
OUT=$(cd "$OUT" && pwd)

for a in $ADOPT; do
  if (( a < 0 || a > TOTAL_VO )); then
    echo "ADOPT value $a is outside 0..$TOTAL_VO" >&2
    exit 1
  fi
done

echo "Building once..."
( cd "$NS3_DIR" && ./ns3 build >"$OUT/logs/build.log" 2>&1 ) || {
  echo "Build failed, see $OUT/logs/build.log" >&2
  exit 1
}

run_job() {
  # job format: load:nVoLegacy:nVoPedca:seed
  IFS=: read -r load leg ped seed <<<"$1"
  local label="L${load}_P${ped}of$((leg + ped))_s${seed}"
  local csv="$OUT/raw/$label.csv"
  rm -f "$csv"
  ( cd "$NS3_DIR" && ./ns3 run --no-build \
      "$SCENARIO --nVoLegacy=$leg --nVoPedca=$ped --perAcLoadMbps=$load \
       --rngRun=$seed --scenarioLabel=$label --outputCsv=$csv $EXTRA" \
      >"$OUT/logs/$label.log" 2>&1 ) \
    && echo "done  $label" \
    || echo "FAIL  $label (see logs/$label.log)"
}
export -f run_job
export OUT NS3_DIR SCENARIO EXTRA

JOBLIST=()
for load in $LOADS; do
  for ped in $ADOPT; do
    leg=$((TOTAL_VO - ped))
    for seed in $(seq 1 "$SEEDS"); do
      JOBLIST+=("$load:$leg:$ped:$seed")
    done
  done
done

echo "Running ${#JOBLIST[@]} jobs on $JOBS workers -> $OUT"
printf '%s\n' "${JOBLIST[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_job "{}"'

# Merge per-run CSVs (one file per run avoids append races between parallel jobs)
MERGED="$OUT/pedca_compare.csv"
first=1
for f in "$OUT"/raw/*.csv; do
  [[ -s "$f" ]] || continue
  if (( first )); then
    cat "$f" >"$MERGED"
    first=0
  else
    tail -n +2 "$f" >>"$MERGED"
  fi
done

if (( first )); then
  echo "No results produced; check $OUT/logs" >&2
  exit 1
fi

echo
echo "Merged CSV: $MERGED"

# Quick summary: AC_VO only, mean over seeds, per (load, P-EDCA station count)
if command -v python3 >/dev/null 2>&1; then
  python3 - "$MERGED" <<'PY'
import sys
try:
    import pandas as pd
except ImportError:
    print("pandas not installed; skipping summary")
    sys.exit(0)

df = pd.read_csv(sys.argv[1])
vo = df[df["ac"].isin(["AC_VO_LEGACY", "AC_VO_PEDCA"]) & (df["stationsInAc"] > 0)]
cols = ["pdr", "meanDelayMs", "p99DelayMs", "p999DelayMs",
        "macDataAttempts", "macRetransmissions", "dsCtsTransmissions",
        "stage2RtsTransmissions"]
g = (vo.groupby(["perAcOfferedLoadMbps", "nVoPedca", "ac"])[cols]
       .mean().round(4))
pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 20)
print(g)
PY
fi
