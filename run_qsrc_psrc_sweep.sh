#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Brute-force sweep of the P-EDCA QSRC and PSRC thresholds.
#
# Calls your existing experiment script once per (QSRC, PSRC) pair, each in its own
# output folder, so file names and your analysis scripts keep working unchanged.
#
#   QSRC threshold : 1..3  (2-bit field in the draft, 0 reserved)
#   PSRC threshold : 1..4  (3-bit field in the draft, 0 and >4 reserved)
#   => 12 combinations
#
# 0% adoption has no P-EDCA STA, so the thresholds cannot matter there: it is run ONCE
# in <OUT_ROOT>/baseline_0pct and reused for every combination by the aggregator.
#
# Usage (from the ns-3 root):
#   ./run_qsrc_psrc_sweep.sh [options-of-your-experiment-script]
#   ./run_qsrc_psrc_sweep.sh --load 12 --sim-time 60 --jobs 8
#   QSRC_LIST="2 3" PSRC_LIST="1 2" ./run_qsrc_psrc_sweep.sh --smoke
#
# Environment overrides:
#   EXP1            experiment script        (default ./run_experiment1_full.sh)
#   OUT_ROOT        results root             (default results/qp_sweep)
#   QSRC_LIST       default "1 2 3"
#   PSRC_LIST       default "1 2 3 4"
#   ADOPTION_LIST   default "25 50 75 100"   (0 is added automatically as baseline)
#   TRAFFIC_LIST    default "cbr poisson poissonBurst"
#   PER_COMBO_ANALYSIS=1   also run your analyse_pedca.py inside every combination
#
# Re-running the same command resumes: finished run files are skipped by EXP1.
# ==============================================================================

EXP1="${EXP1:-./run_experiment1_full.sh}"
OUT_ROOT="${OUT_ROOT:-results/qp_sweep}"
QSRC_LIST="${QSRC_LIST:-1 2 3}"
PSRC_LIST="${PSRC_LIST:-1 2 3 4}"
ADOPTION_LIST="${ADOPTION_LIST:-25 50 75 100}"
TRAFFIC_LIST="${TRAFFIC_LIST:-cbr poisson poissonBurst}"
PER_COMBO_ANALYSIS="${PER_COMBO_ANALYSIS:-0}"

[[ -x "$EXP1" ]] || { echo "ERROR: $EXP1 not found or not executable (set EXP1=...)." >&2; exit 1; }
for q in $QSRC_LIST; do
  [[ "$q" =~ ^[1-3]$ ]] || { echo "ERROR: QSRC threshold must be 1-3 (got '$q')." >&2; exit 1; }
done
for p in $PSRC_LIST; do
  [[ "$p" =~ ^[1-4]$ ]] || { echo "ERROR: PSRC threshold must be 1-4 (got '$p')." >&2; exit 1; }
done
ADOPTION_LIST="$(echo "$ADOPTION_LIST" | tr ' ' '\n' | grep -vx '0' | tr '\n' ' ' || true)"

EXTRA_ARGS=("$@")
NOANALYSIS=(); [[ "$PER_COMBO_ANALYSIS" == 1 ]] || NOANALYSIS=(--no-analysis)

mkdir -p "$OUT_ROOT"
FAILED="$OUT_ROOT/failed_combos.txt"; : > "$FAILED"

NQ=$(echo $QSRC_LIST | wc -w | tr -d ' '); NP=$(echo $PSRC_LIST | wc -w | tr -d ' ')
echo "=============================================================="
echo "QSRC x PSRC sweep:  QSRC [$QSRC_LIST] x PSRC [$PSRC_LIST] = $((NQ*NP)) combinations"
echo "Adoption (+0% baseline once): [$ADOPTION_LIST]   Traffic: [$TRAFFIC_LIST]"
echo "Experiment script: $EXP1      Output root: $OUT_ROOT"
echo "Forwarded options: ${EXTRA_ARGS[*]-(none)}"
echo "=============================================================="

# --out is placed LAST on purpose: it must win over any --out/--smoke in the forwarded options.
echo; echo ">>> baseline (0% P-EDCA, run once)"
"$EXP1" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ${NOANALYSIS[@]+"${NOANALYSIS[@]}"} \
        --adoption 0 --traffic "$TRAFFIC_LIST" --out "$OUT_ROOT/baseline_0pct" \
  || echo "baseline" >> "$FAILED"

for q in $QSRC_LIST; do
  for p in $PSRC_LIST; do
    echo; echo ">>> QSRC=$q  PSRC=$p"
    "$EXP1" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ${NOANALYSIS[@]+"${NOANALYSIS[@]}"} \
            --qsrc "$q" --psrc "$p" --adoption "$ADOPTION_LIST" --traffic "$TRAFFIC_LIST" \
            --out "$OUT_ROOT/q${q}_p${p}" \
      || echo "q${q}_p${p}" >> "$FAILED"
  done
done

echo
if [[ -s "$FAILED" ]]; then
  echo "Combinations with failed runs (re-run the same command to retry only those):"; cat "$FAILED"
fi
if [[ -f aggregate_qsrc_psrc.py ]]; then
  python3 aggregate_qsrc_psrc.py "$OUT_ROOT" || echo "(aggregation failed)"
else
  echo "aggregate_qsrc_psrc.py not found here: run it later with  python3 aggregate_qsrc_psrc.py $OUT_ROOT"
fi
[[ -s "$FAILED" ]] && exit 1
exit 0
