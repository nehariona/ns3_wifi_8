#!/usr/bin/env bash
#
# run_sweeps.sh - launch the P-EDCA vs EDCA sweeps for pedca-final.cc
#
# Usage:
#   ./run_sweeps.sh all
#   ./run_sweeps.sh adoption load            # any subset
#   DRY=1 ./run_sweeps.sh all                # only print the commands
#
# Sweeps (names follow your Excel; Exp numbers differ between Summary and Run List):
#   adoption  Exp 1  % P-EDCA among AC_VO       0/25/50/75/100, cbr+poisson+poissonBurst
#   load      Exp 2  load per AC (Mbps)         3/6/12/24/48, adoption 0 and 100, 3 traffic models
#   ratio     Exp 3  STA mix per AC (8 scenarios), adoption 0 and 100, 1.5 Mbps/STA
#   qsrc      Exp 4  QSRC 1..4, adoption 50
#   psrc      Exp 5  PSRC 2,3,   adoption 50
#   stas      Exp 6  total STAs (5:1:1:1 ... 160:32:32:32), adoption 0 and 100, 1.5 Mbps/STA
#   payload   Exp 8  payload 256/512/1024/1500 B, adoption 50
# NOT included: AIFSN and CW sweeps - the .cc has no option for them yet.
#
# Settings (environment variables):
#   NS3_DIR   ns-3 root                                  (default: $HOME/ns-3.48)
#   SCENARIO  scratch program name                       (default: scratch/pedca-final)
#   BIN       full path of a built binary; if set it is run directly instead of ./ns3 run
#   SEEDS     seeds per config (rngRun = 1..SEEDS)       (default: 5)
#   JOBS      parallel simulations                       (default: 4)
#   OUT       results directory                          (default: ./results/final)
#   TRAFFIC_OTHER traffic model for Exp 3-7              (default: poissonBurst, as in the Summary)
#   EXTRA     extra args passed to every run, e.g. "--simulationTime=30 --delayBinWidthUs=10"
#
# Every run writes its OWN csv ($OUT/<sweep>/runs/<label>_run<seed>.csv), so parallel runs
# never fight over one file. A run whose csv already exists is skipped, so re-running the
# script resumes an interrupted sweep. Delete a csv to force that run again.

set -euo pipefail

NS3_DIR="${NS3_DIR:-$HOME/ns3_wifi_8}"
SCENARIO="${SCENARIO:-scratch/pedca-final}"
BIN="${BIN:-}"
SEEDS="${SEEDS:-5}"
JOBS="${JOBS:-4}"
OUT="$(mkdir -p "${OUT:-results/final}" && cd "${OUT:-results/final}" && pwd)"
TRAFFIC_OTHER="${TRAFFIC_OTHER:-poissonBurst}"
EXTRA="${EXTRA:---delayBinWidthUs=10}"   # 10 us bins -> tight min/max delay
DRY="${DRY:-0}"

ALL_TRAFFIC="cbr poisson poissonBurst"
LOAD_PER_AC=12            # Mbps, Summary!B4
PER_STA_LOAD=1.5          # Mbps, Exp 3 and Exp 6
JOBFILE="$OUT/jobs.txt"
: > "$JOBFILE"

# ---------------------------------------------------------------------------------------
# add_jobs SWEEP XVAL TRAFFIC ADOPT_PCT nVO nVI nBE nBK LOAD_ARGS
#   XVAL is what the analyzer puts on the x axis; it must not contain "_".
# ---------------------------------------------------------------------------------------
add_jobs() {
  local sweep="$1" x="$2" traffic="$3" adopt="$4" vo="$5" vi="$6" be="$7" bk="$8" loadargs="$9"; shift 9
  local pedca=$(( (vo * adopt + 50) / 100 ))
  local legacy=$(( vo - pedca ))
  local label="${sweep}_${x}_${traffic}_a${adopt}"
  local dir="$OUT/$sweep"
  mkdir -p "$dir/runs" "$dir/logs"

  local s
  for s in $(seq 1 "$SEEDS"); do
    local csv="$dir/runs/${label}_run${s}.csv"
    [[ -s "$csv" ]] && continue                      # already done
    local args="--nVoLegacy=$legacy --nVoPedca=$pedca --nVi=$vi --nBe=$be --nBk=$bk"
    args+=" --trafficModel=$traffic $loadargs $* $EXTRA"
    args+=" --rngSeed=1 --rngRun=$s --scenarioLabel=$label --outputCsv=$csv"
    local log="$dir/logs/${label}_run${s}.log"
    rm -f "$csv"
    if [[ -n "$BIN" ]]; then
      echo "$BIN $args > $log 2>&1" >> "$JOBFILE"
    else
      echo "cd $NS3_DIR && ./ns3 run --no-build \"$SCENARIO $args\" > $log 2>&1" >> "$JOBFILE"
    fi
  done
}

per_ac()  { echo "--perAcLoadMbps=$1"; }
per_sta() { echo "--perStationLoadFixed=1 --perStationLoadMbpsFixed=$1"; }

# ---------------------------------------------------------------------------------------
# Sweeps
# ---------------------------------------------------------------------------------------
sweep_adoption() {                 # Exp 1: 32 STAs = 20:4:4:4
  local t a
  for t in $ALL_TRAFFIC; do for a in 0 25 50 75 100; do
    add_jobs adoption "$a" "$t" "$a" 20 4 4 4 "$(per_ac $LOAD_PER_AC)"
  done; done
}

sweep_load() {                     # Exp 2
  local t a l
  for t in $ALL_TRAFFIC; do for a in 0 100; do for l in 3 6 12 24 48; do
    add_jobs load "$l" "$t" "$a" 20 4 4 4 "$(per_ac "$l")"
  done; done; done
}

sweep_ratio() {                    # Exp 3: scenario name nVo nVi nBe nBk (Exp3_Scenarios sheet)
  local a row name vo vi be bk
  local scenarios=(
    "Baseline 8 8 8 8"
    "VO-heavy 20 4 4 4"
    "BK-heavy 4 4 4 20"
    "InvertedPyramid 2 4 10 16"
    "Pyramid 4 8 8 12"
    "HighPriorityPolarized 14 14 2 2"
    "LowPriorityPolarized 2 2 14 14"
    "ExtremeSingleStation 1 1 1 29"
  )
  for a in 0 100; do for row in "${scenarios[@]}"; do
    read -r name vo vi be bk <<< "$row"
    add_jobs ratio "$name" "$TRAFFIC_OTHER" "$a" "$vo" "$vi" "$be" "$bk" "$(per_sta $PER_STA_LOAD)"
  done; done
}

sweep_qsrc() {                     # Exp 4
  local q
  for q in 1 2 3 4; do
    add_jobs qsrc "$q" "$TRAFFIC_OTHER" 50 20 4 4 4 "$(per_ac $LOAD_PER_AC)" --pedcaQsrcThreshold="$q"
  done
}

sweep_psrc() {                     # Exp 5
  local p
  for p in 2 3; do
    add_jobs psrc "$p" "$TRAFFIC_OTHER" 50 20 4 4 4 "$(per_ac $LOAD_PER_AC)" --pedcaPsrcThreshold="$p"
  done
}

sweep_stas() {                     # Exp 6: (5:1:1:1) ... (160:32:32:32); needs the /16 address fix
  local a k total
  for a in 0 100; do for k in 1 2 4 8 16 32; do
    total=$(( 8 * k ))             # 5k + k + k + k
    add_jobs stas "$total" "$TRAFFIC_OTHER" "$a" $((5*k)) "$k" "$k" "$k" "$(per_sta $PER_STA_LOAD)"
  done; done
}

sweep_payload() {                  # Exp 8
  local b
  for b in 256 512 1024 1500; do
    add_jobs payload "$b" "$TRAFFIC_OTHER" 50 20 4 4 4 "$(per_ac $LOAD_PER_AC)" --payloadSize="$b"
  done
}

# ---------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------
[[ $# -eq 0 ]] && { sed -n '3,25p' "$0"; exit 1; }
sweeps=("$@")
[[ "${sweeps[0]}" == "all" ]] && sweeps=(adoption load ratio qsrc psrc stas payload)

for sw in "${sweeps[@]}"; do
  declare -F "sweep_$sw" > /dev/null || { echo "unknown sweep: $sw" >&2; exit 1; }
  "sweep_$sw"
done

n=$(wc -l < "$JOBFILE")
echo "Sweeps: ${sweeps[*]} | seeds: $SEEDS | runs still to do: $n | parallel jobs: $JOBS"
[[ "$DRY" == "1" ]] && { cat "$JOBFILE"; exit 0; }
[[ "$n" -eq 0 ]] && { echo "Nothing to run."; exit 0; }

# GNU xargs: one job line per run, $JOBS at a time; keep going if one run fails
fail=0
xargs -d '\n' -P "$JOBS" -I{} bash -c {} < "$JOBFILE" || fail=1

done_n=$(find "$OUT" -path '*/runs/*.csv' -size +0 | wc -l)
echo "Finished. CSVs present: $done_n. Logs: $OUT/<sweep>/logs/"
[[ "$fail" -eq 1 ]] && echo "WARNING: some runs failed - check the logs of runs with no csv." >&2
echo "Next: python3 analyze_results.py --results $OUT"

