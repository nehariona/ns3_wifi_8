#!/usr/bin/env bash
# =============================================================================
# exp6_full_script_final.sh
#
# Experiment 6: EDCA (0 % adoption) vs P-EDCA (100 % adoption) for VO traffic
#               while the total number of stations scales.
#
#   STA mixes  (VO:VI:BE:BK) : 5:1:1:1, 10:2:2:2, 15:3:3:3, 20:4:4:4, 30:6:6:6
#   Traffic                  : Poisson burst, 1 Mbps / STA (mean)
#   P-EDCA adoption          : 0 % (all VO legacy EDCA) and 100 % (all VO P-EDCA)
#   qsrc / psrc thresholds   : 3 / 4
#   Simulation time          : 200 s
#   Seeds                    : 2 (rngSeed = 1,2), 1 run each (rngRun = 1)
#
# Total runs = 5 mixes x 2 adoption levels x 2 seeds = 20
#
# Usage:   ./exp6_full_script_final.sh
# Useful env overrides:
#   JOBS=8          parallel simulations (default 7)
#   FORCE=1         re-run even if a run's result CSV already exists
#   SKIP_BUILD=1    do not call ./ns3 build first
#   SKIP_ANALYSIS=1 do not call analyze_exp6.py at the end
#   SIM_PROGRAM=... ns-3 program name (EDIT THE DEFAULT BELOW if needed)
# =============================================================================
set -u -o pipefail

# ----------------------------- paths / program -------------------------------
NS3_DIR="${NS3_DIR:-/Users/neharionaalice/Downloads/ns-3.48}"
OUT_DIR="${OUT_DIR:-$NS3_DIR/results/exp6_final}"

# >>> EDIT: name of your simulation as ns3 knows it (scratch/<name> or <name>)
SIM_PROGRAM="${SIM_PROGRAM:-scratch/pedca-txop-ratio-sweep.cc}"

# >>> EDIT only if your simulator spells the CSV-output option differently.
ARG_CSV="${ARG_CSV:-outputCsv}"

JOBS="${JOBS:-8}"
FORCE="${FORCE:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_ANALYSIS="${SKIP_ANALYSIS:-0}"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS_DIR="$OUT_DIR/runs"
SUPPORTED_FILE="$OUT_DIR/.supported_args.txt"
UNSUPPORTED_LOG="$OUT_DIR/unsupported_args.log"
CUMULATIVE_CSV="$OUT_DIR/exp6_cumulative.csv"

# ----------------------------- experiment design -----------------------------
MIXES="5:1:1:1 10:2:2:2 15:3:3:3 20:4:4:4 30:6:6:6"   # VO:VI:BE:BK
ADOPTIONS="0 100"                                     # % of VO STAs using P-EDCA
SEEDS="1 2 "
RNG_RUN=1

SIM_TIME=200
PER_STA_LOAD_MBPS=3
TRAFFIC_MODEL="poissonBurst"
PRESERVE_MEAN_LOAD=true
QSRC=3
PSRC=4
PCAP_ENABLED=false

# Optional knobs.  Left empty => not passed => simulator default is used.
BSS_RADIUS="${BSS_RADIUS:-}"
LOAD_POLICY="${LOAD_POLICY:-}"
BURST_ON_TIME="${BURST_ON_TIME:-}"
BURST_OFF_MEAN="${BURST_OFF_MEAN:-}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-}"
PHY_DATA_RATE="${PHY_DATA_RATE:-}"
PHY_CONTROL_RATE="${PHY_CONTROL_RATE:-}"
WARMUP_TIME="${WARMUP_TIME:-}"
DRAIN_TIME="${DRAIN_TIME:-}"
PEDCA_DS_AIFSN="${PEDCA_DS_AIFSN:-}"
PEDCA_CW_DS="${PEDCA_CW_DS:-}"
PEDCA_STAGE2_AIFSN="${PEDCA_STAGE2_AIFSN:-}"
PEDCA_STAGE2_CWMIN="${PEDCA_STAGE2_CWMIN:-}"
PEDCA_STAGE2_CWMAX="${PEDCA_STAGE2_CWMAX:-}"
PEDCA_STAGE2_WINDOW_US="${PEDCA_STAGE2_WINDOW_US:-}"

# Columns the cumulative CSV is expected to contain (checked after merging)
EXPECTED_COLUMNS="protocol scenarioLabel ac numStations nBe nBk nVi nVoLegacy nVoPedca pedcaAdoptionRatio stationsInAc bssRadius loadPolicy perStationLoadMbps perAcOfferedLoadMbps trafficModel burstOnTime burstOffMean preserveMeanLoad peakRateMbpsPerSta meanOfferedLoadMbpsPerAc payloadSize phyDataRateMbps phyControlRateMbps simulationTime warmupTime drainTime rngSeed rngRun pedcaQsrcThreshold pedcaPsrcThreshold pedcaDsAifsn pedcaCwDs pedcaStage2Aifsn pedcaStage2CwMin pedcaStage2CwMax pedcaStage2WindowUs throughputMbps payloadGoodputMbps pdr packetLossRate meanDelayMs meanJitterMs p95DelayMs p99DelayMs p999DelayMs jitterSamples txPackets rxPackets txBytes rxBytes flowMonitorLostPackets macDataAttempts macRetransmissions dsCtsTransmissions stage2RtsTransmissions apPedcaSupported sameContentMaxDelayNs pcapEnabled"

# =============================================================================
# WORKER: run exactly one simulation
#   args: label ratioPct nVo nVi nBe nBk seed run
# =============================================================================
ARGS=()
add_arg() {   # add_arg name value  -> appended only if simulator supports it
  local name="$1" value="$2"
  [ -z "$value" ] && return 0
  if [ -s "$SUPPORTED_FILE" ] && ! grep -qx -- "$name" "$SUPPORTED_FILE"; then
    echo "$name" >> "$UNSUPPORTED_LOG"
    return 0
  fi
  ARGS+=("--${name}=${value}")
}

run_one() {
  local label="$1" ratio="$2" vo="$3" vi="$4" be="$5" bk="$6" seed="$7" rng="$8"
  local total=$(( vo + vi + be + bk ))
  local proto="EDCA"; [ "$ratio" -gt 0 ] && proto="PEDCA"
  local nvo_pedca=$(( (vo * ratio + 50) / 100 ))
  local nvo_legacy=$(( vo - nvo_pedca ))
  local ratio_frac; ratio_frac=$(awk -v r="$ratio" 'BEGIN{printf "%.2f", r/100}')

  local run_id="${label}_n${total}_seed${seed}_run${rng}"
  local run_dir="$RUNS_DIR/$run_id"
  local csv="$run_dir/results.csv"
  mkdir -p "$run_dir"

  if [ "$FORCE" != "1" ] && [ -s "$csv" ]; then
    echo "[skip ] $run_id (results.csv exists)"
    return 0
  fi
  rm -f "$run_dir/STATUS"

  ARGS=()
  add_arg scenarioLabel       "$label"
  add_arg nVi                 "$vi"
  add_arg nBe                 "$be"
  add_arg nBk                 "$bk"
  add_arg nVoLegacy           "$nvo_legacy"
  add_arg nVoPedca            "$nvo_pedca"
  add_arg bssRadius           "$BSS_RADIUS"
  add_arg loadPolicy          "$LOAD_POLICY"
  add_arg perStationLoadFixed "true"
  add_arg perStationLoadMbpsFixed "$PER_STA_LOAD_MBPS"
  add_arg trafficModel        "$TRAFFIC_MODEL"
  add_arg burstOnTime         "$BURST_ON_TIME"
  add_arg burstOffMean        "$BURST_OFF_MEAN"
  add_arg preserveMeanLoad    "$PRESERVE_MEAN_LOAD"
  add_arg payloadSize         "$PAYLOAD_SIZE"
  add_arg phyDataRateMbps     "$PHY_DATA_RATE"
  add_arg phyControlRateMbps  "$PHY_CONTROL_RATE"
  add_arg simulationTime      "$SIM_TIME"
  add_arg warmupTime          "$WARMUP_TIME"
  add_arg drainTime           "$DRAIN_TIME"
  add_arg rngSeed             "$seed"
  add_arg rngRun              "$rng"
  add_arg pedcaQsrcThreshold  "$QSRC"
  add_arg pedcaPsrcThreshold  "$PSRC"
  add_arg pedcaDsAifsn        "$PEDCA_DS_AIFSN"
  add_arg pedcaCwDs           "$PEDCA_CW_DS"
  add_arg pedcaStage2Aifsn    "$PEDCA_STAGE2_AIFSN"
  add_arg pedcaStage2CwMin    "$PEDCA_STAGE2_CWMIN"
  add_arg pedcaStage2CwMax    "$PEDCA_STAGE2_CWMAX"
  add_arg pedcaStage2WindowUs "$PEDCA_STAGE2_WINDOW_US"
  add_arg enablePcap          "$PCAP_ENABLED"
  add_arg "$ARG_CSV"          "$csv"

  printf '%s\n' "${ARGS[@]}" > "$run_dir/params.txt"

  local t0; t0=$(date +%s)
  echo "[start] $run_id"
  ( cd "$NS3_DIR" && ./ns3 run --no-build --cwd="$run_dir" "$SIM_PROGRAM ${ARGS[*]}" ) \
      > "$run_dir/run.log" 2>&1
  local rc=$?
  local t1; t1=$(date +%s)

  # Fallback: simulator ignored the CSV option -> grab any csv it wrote here
  if [ ! -s "$csv" ]; then
    local alt; alt=$(find "$run_dir" -maxdepth 1 -name '*.csv' ! -name 'results.csv' | head -n 1)
    [ -n "$alt" ] && cp "$alt" "$csv"
  fi

  if [ $rc -eq 0 ] && [ -s "$csv" ]; then
    echo "ok $((t1 - t0))s" > "$run_dir/STATUS"
    echo "[done ] $run_id  ($((t1 - t0))s)"
  else
    echo "FAIL rc=$rc" > "$run_dir/STATUS"
    echo "[FAIL ] $run_id  rc=$rc  (see $run_dir/run.log)"
  fi
  return 0
}

if [ "${1:-}" = "__run_one" ]; then
  shift
  run_one "$@"
  exit 0
fi

# =============================================================================
# MAIN
# =============================================================================
echo "=============================================================="
echo " Experiment 6"
echo "  ns-3 dir : $NS3_DIR"
echo "  program  : $SIM_PROGRAM"
echo "  output   : $OUT_DIR"
echo "  parallel : $JOBS job(s)"
echo "=============================================================="

if [ ! -x "$NS3_DIR/ns3" ]; then
  echo "ERROR: $NS3_DIR/ns3 not found / not executable." >&2
  exit 1
fi

mkdir -p "$RUNS_DIR"
: > "$UNSUPPORTED_LOG"

# ---- 1. build ---------------------------------------------------------------
if [ "$SKIP_BUILD" != "1" ]; then
  echo "[build] ./ns3 build ..."
  if ! ( cd "$NS3_DIR" && ./ns3 build ) > "$OUT_DIR/build.log" 2>&1; then
    echo "ERROR: build failed, see $OUT_DIR/build.log" >&2
    tail -n 25 "$OUT_DIR/build.log" >&2
    exit 1
  fi
fi

# ---- 2. probe which command-line options the simulator really accepts ------
echo "[probe] reading --PrintHelp of $SIM_PROGRAM ..."
( cd "$NS3_DIR" && ./ns3 run --no-build "$SIM_PROGRAM --PrintHelp" ) > "$OUT_DIR/printhelp.txt" 2>&1
sed -nE 's/^[[:space:]]*--([A-Za-z0-9_.]+):.*/\1/p' "$OUT_DIR/printhelp.txt" | sort -u > "$SUPPORTED_FILE"
if [ ! -s "$SUPPORTED_FILE" ]; then
  echo "WARNING: could not read the option list (see $OUT_DIR/printhelp.txt)."
  echo "         Is SIM_PROGRAM='$SIM_PROGRAM' correct?  All options will be passed unfiltered."
else
  echo "[probe] simulator accepts $(wc -l < "$SUPPORTED_FILE" | tr -d ' ') options"
  if ! grep -qx -- "$ARG_CSV" "$SUPPORTED_FILE"; then
    echo "WARNING: option --$ARG_CSV not found; will fall back to any *.csv written in each run folder."
  fi
fi

# ---- 3. build the job list --------------------------------------------------
JOBLIST="$OUT_DIR/joblist.txt"
: > "$JOBLIST"
for mix in $MIXES; do
  IFS=':' read -r vo vi be bk <<< "$mix"
  for ratio in $ADOPTIONS; do
    if [ "$ratio" -eq 0 ]; then label="EDCA0"; else label="PEDCA${ratio}"; fi
    for seed in $SEEDS; do
      echo "$label $ratio $vo $vi $be $bk $seed $RNG_RUN" >> "$JOBLIST"
    done
  done
done
NJOBS=$(wc -l < "$JOBLIST" | tr -d ' ')
echo "[plan ] $NJOBS simulations"

# ---- 4. run -----------------------------------------------------------------
export NS3_DIR OUT_DIR SIM_PROGRAM ARG_CSV FORCE RUNS_DIR SUPPORTED_FILE UNSUPPORTED_LOG
export SIM_TIME PER_STA_LOAD_MBPS TRAFFIC_MODEL PRESERVE_MEAN_LOAD QSRC PSRC PCAP_ENABLED
export BSS_RADIUS LOAD_POLICY BURST_ON_TIME BURST_OFF_MEAN PAYLOAD_SIZE PHY_DATA_RATE PHY_CONTROL_RATE
export WARMUP_TIME DRAIN_TIME PEDCA_DS_AIFSN PEDCA_CW_DS PEDCA_STAGE2_AIFSN PEDCA_STAGE2_CWMIN
export PEDCA_STAGE2_CWMAX PEDCA_STAGE2_WINDOW_US

T_START=$(date +%s)
xargs -P "$JOBS" -L 1 "$SELF" __run_one < "$JOBLIST" || true
T_END=$(date +%s)
echo "[time ] all runs finished in $(( (T_END - T_START) / 60 )) min"

# ---- 5. status report -------------------------------------------------------
N_OK=0; N_FAIL=0
for d in "$RUNS_DIR"/*/; do
  [ -f "$d/STATUS" ] || continue
  if grep -q '^ok' "$d/STATUS"; then N_OK=$((N_OK + 1)); else N_FAIL=$((N_FAIL + 1)); echo "  FAILED: $(basename "$d")"; fi
done
echo "[stat ] ok=$N_OK  failed=$N_FAIL"

if [ -s "$UNSUPPORTED_LOG" ]; then
  sort -u "$UNSUPPORTED_LOG" > "$UNSUPPORTED_LOG.tmp" && mv "$UNSUPPORTED_LOG.tmp" "$UNSUPPORTED_LOG"
  echo "[note ] options NOT accepted by the simulator (dropped, see $UNSUPPORTED_LOG):"
  sed 's/^/          --/' "$UNSUPPORTED_LOG"
fi

# ---- 6. merge into one cumulative CSV --------------------------------------
: > "$CUMULATIVE_CSV"
FIRST=1
while IFS= read -r f; do
  rd="$(basename "$(dirname "$f")")"
  tr -d '\r' < "$f" | awk -v rd="$rd" -v first="$FIRST" '
      NR==1 { if (first == 1) print $0 ",runDir"; next }
      NF    { print $0 "," rd }' >> "$CUMULATIVE_CSV"
  FIRST=0
done < <(find "$RUNS_DIR" -mindepth 2 -maxdepth 2 -name results.csv | sort)

if [ ! -s "$CUMULATIVE_CSV" ]; then
  echo "ERROR: no results.csv files were produced - check $RUNS_DIR/*/run.log" >&2
  exit 1
fi
echo "[merge] $CUMULATIVE_CSV  ($(( $(wc -l < "$CUMULATIVE_CSV") - 1 )) data rows)"

HEADER=$(head -n 1 "$CUMULATIVE_CSV")
MISSING=""
for c in $EXPECTED_COLUMNS; do
  case ",$HEADER," in *",$c,"*) ;; *) MISSING="$MISSING $c";; esac
done
[ -n "$MISSING" ] && echo "[warn ] columns missing from simulator CSV:$MISSING"

# ---- 7. analysis / graphs ---------------------------------------------------
if [ "$SKIP_ANALYSIS" != "1" ]; then
  PY="$SELF_DIR/analyze_exp6.py"
  if [ -f "$PY" ] && command -v python3 > /dev/null 2>&1; then
    echo "[plot ] python3 $PY"
    python3 "$PY" --csv "$CUMULATIVE_CSV" --out "$OUT_DIR/analysis" \
      || echo "[warn ] analysis script failed (needs pandas, numpy, matplotlib)"
  else
    echo "[plot ] skipped (analyze_exp6.py not next to this script, or python3 missing)"
  fi
fi

echo "Done.  Results: $OUT_DIR"
