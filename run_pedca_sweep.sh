#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# P-EDCA adoption sweep (ns-3.48): scenarios x loads x A-MPDU modes x runs
#
# Run from the ns-3 root directory:
#   ./run_pedca_sweep.sh --runs 10 --loads "1 2.5 5 10" --ampdu "0 1" --jobs 4
#
# Every run writes its own CSV under <out-dir>/raw/, so parallel jobs
# never write to the same file. Merge/analyse with analyse_pedca.py.
# ================================================================

PROGRAM="${PROGRAM:-scratch/pedca-360mhz}"        # scratch target name (file pedca-360mhz.cc)
SCENARIOS_CSV="${SCENARIOS_CSV:-pedca_ratio_scenarios.csv}"
OUT_DIR="${OUT_DIR:-results/sweep}"

NUM_RUNS="${NUM_RUNS:-10}"
RNG_SEED="${RNG_SEED:-1}"
JOBS="${JOBS:-1}"

LOADS="${LOADS:-1 2.5 5 10}"          # Mbps per AC (list)
AMPDU_MODES="${AMPDU_MODES:-0 1}"     # 0 = A-MPDU enabled, 1 = disabled (list)
CLEAN_BASELINE="${CLEAN_BASELINE:-0}" # 1 = scenarios with nVoPedca=0 run with apPedcaSupported=0 (off by default)

TRAFFIC_MODEL="${TRAFFIC_MODEL:-poissonBurst}"   # poissonBurst | poisson | cbr
BURST_ON_TIME="${BURST_ON_TIME:-1.0}"
BURST_OFF_MEAN="${BURST_OFF_MEAN:-2.0}"
PRESERVE_MEAN_LOAD="${PRESERVE_MEAN_LOAD:-1}"
PER_STATION_LOAD_FIXED="${PER_STATION_LOAD_FIXED:-0}"
PER_STATION_LOAD_MBPS="${PER_STATION_LOAD_MBPS:-0.25}"

PAYLOAD_SIZE="${PAYLOAD_SIZE:-1024}"
SIM_TIME="${SIM_TIME:-60}"
WARMUP_TIME="${WARMUP_TIME:-5}"
DRAIN_TIME="${DRAIN_TIME:-5}"
BSS_RADIUS="${BSS_RADIUS:-5}"

# PHY (only passed if set; the .cc has its own defaults)
DATA_MODE="${DATA_MODE:-}"
PHY_DATA_RATE_MBPS="${PHY_DATA_RATE_MBPS:-}"   # keep consistent with DATA_MODE (CSV label only)

# P-EDCA
PEDCA_QSRC_THR="${PEDCA_QSRC_THR:-1}"
PEDCA_PSRC_THR="${PEDCA_PSRC_THR:-4}"
PEDCA_DS_AIFSN="${PEDCA_DS_AIFSN:-2}"
PEDCA_CW_DS="${PEDCA_CW_DS:-7}"
PEDCA_STAGE2_AIFSN="${PEDCA_STAGE2_AIFSN:-2}"
PEDCA_STAGE2_CWMIN="${PEDCA_STAGE2_CWMIN:-3}"
PEDCA_STAGE2_CWMAX="${PEDCA_STAGE2_CWMAX:-7}"
PEDCA_STAGE2_WINDOW_US="${PEDCA_STAGE2_WINDOW_US:-0}"
AP_PEDCA="${AP_PEDCA:-1}"
SAME_CONTENT_MAX_DELAY_NS="${SAME_CONTENT_MAX_DELAY_NS:-800}"

# Optional: needs a matching cmd.AddValue in the .cc (see notes). Empty = not passed.
QUEUE_MAX_DELAY_MS="${QUEUE_MAX_DELAY_MS:-}"

ENABLE_PCAP="${ENABLE_PCAP:-0}"
PCAP_DIRECTORY="${PCAP_DIRECTORY:-results/pcap}"
FORCE="${FORCE:-0}"      # 1 = overwrite existing raw files, 0 = skip finished runs (resume)
EXTRA_ARGS="${EXTRA_ARGS:-}"   # any extra "--foo=bar" flags for the program

usage() {
cat <<'USAGE'
Usage: ./run_pedca_sweep.sh [options]

Sweep:
  --scenarios FILE     scenario CSV (scenarioLabel,nVoLegacy,nVoPedca,nVi,nBe,nBk)
  --out-dir DIR        output directory (raw CSVs in DIR/raw)
  --runs N             RngRun replicates per point (default 10)
  --seed N             RngSeed
  --loads "a b c"      per-AC loads in Mbps, space separated
  --ampdu "0 1"        A-MPDU modes: 0 = enabled, 1 = disabled
  --jobs N             parallel runs
  --program NAME       ns-3 scratch target
  --force              redo runs whose raw CSV already exists
  --clean-baseline     run 0% scenarios with apPedcaSupported=0 (off by default)

Traffic:     --traffic NAME  --burst-on S  --burst-off S  --preserve-mean 0|1
             --per-station-fixed 0|1  --station-load Mbps
Simulation:  --payload B  --sim-time S  --warmup S  --drain S  --radius M
PHY:         --data-mode EhtMcsN  --phy-rate-mbps X  --queue-max-delay-ms N
P-EDCA:      --qsrc-threshold N  --psrc-threshold N  --ds-aifsn N  --cw-ds N
             --stage2-aifsn N  --stage2-cwmin N  --stage2-cwmax N
             --stage2-window-us N  --ap-pedca 0|1  --same-content-delay-ns N
Other:       --pcap 0|1  --pcap-dir DIR  --extra "--flag=value ..."  -h
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenarios) SCENARIOS_CSV="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --runs) NUM_RUNS="$2"; shift 2 ;;
    --seed) RNG_SEED="$2"; shift 2 ;;
    --loads) LOADS="$2"; shift 2 ;;
    --ampdu) AMPDU_MODES="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --program) PROGRAM="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --no-clean-baseline) CLEAN_BASELINE=0; shift ;;
    --clean-baseline) CLEAN_BASELINE=1; shift ;;
    --traffic) TRAFFIC_MODEL="$2"; shift 2 ;;
    --burst-on) BURST_ON_TIME="$2"; shift 2 ;;
    --burst-off) BURST_OFF_MEAN="$2"; shift 2 ;;
    --preserve-mean) PRESERVE_MEAN_LOAD="$2"; shift 2 ;;
    --per-station-fixed) PER_STATION_LOAD_FIXED="$2"; shift 2 ;;
    --station-load) PER_STATION_LOAD_MBPS="$2"; shift 2 ;;
    --payload) PAYLOAD_SIZE="$2"; shift 2 ;;
    --sim-time) SIM_TIME="$2"; shift 2 ;;
    --warmup) WARMUP_TIME="$2"; shift 2 ;;
    --drain) DRAIN_TIME="$2"; shift 2 ;;
    --radius) BSS_RADIUS="$2"; shift 2 ;;
    --data-mode) DATA_MODE="$2"; shift 2 ;;
    --phy-rate-mbps) PHY_DATA_RATE_MBPS="$2"; shift 2 ;;
    --queue-max-delay-ms) QUEUE_MAX_DELAY_MS="$2"; shift 2 ;;
    --qsrc-threshold) PEDCA_QSRC_THR="$2"; shift 2 ;;
    --psrc-threshold) PEDCA_PSRC_THR="$2"; shift 2 ;;
    --ds-aifsn) PEDCA_DS_AIFSN="$2"; shift 2 ;;
    --cw-ds) PEDCA_CW_DS="$2"; shift 2 ;;
    --stage2-aifsn) PEDCA_STAGE2_AIFSN="$2"; shift 2 ;;
    --stage2-cwmin) PEDCA_STAGE2_CWMIN="$2"; shift 2 ;;
    --stage2-cwmax) PEDCA_STAGE2_CWMAX="$2"; shift 2 ;;
    --stage2-window-us) PEDCA_STAGE2_WINDOW_US="$2"; shift 2 ;;
    --ap-pedca) AP_PEDCA="$2"; shift 2 ;;
    --same-content-delay-ns) SAME_CONTENT_MAX_DELAY_NS="$2"; shift 2 ;;
    --pcap) ENABLE_PCAP="$2"; shift 2 ;;
    --pcap-dir) PCAP_DIRECTORY="$2"; shift 2 ;;
    --extra) EXTRA_ARGS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# ---- Validation -------------------------------------------------
[[ -x ./ns3 ]] || { echo "ERROR: run from the ns-3 root directory." >&2; exit 1; }
[[ -f "$SCENARIOS_CSV" ]] || { echo "ERROR: scenario file not found: $SCENARIOS_CSV" >&2; exit 1; }
[[ "$NUM_RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --runs must be a positive integer." >&2; exit 1; }
[[ "$RNG_SEED" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --seed must be a positive integer." >&2; exit 1; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --jobs must be a positive integer." >&2; exit 1; }
case "$TRAFFIC_MODEL" in poissonBurst|poisson|cbr) ;; *)
  echo "ERROR: traffic must be poissonBurst, poisson or cbr." >&2; exit 1 ;; esac
for m in $AMPDU_MODES; do [[ "$m" == 0 || "$m" == 1 ]] || { echo "ERROR: --ampdu values must be 0 or 1." >&2; exit 1; }; done
for l in $LOADS; do [[ "$l" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "ERROR: bad load '$l'." >&2; exit 1; }; done

RAW_DIR="$OUT_DIR/raw"
mkdir -p "$RAW_DIR" "$PCAP_DIRECTORY"

# Build once so parallel runs do not race on the build.
echo "Building $PROGRAM ..."
./ns3 build >/dev/null || { echo "ERROR: build failed (run ./ns3 build to see why)." >&2; exit 1; }

# ---- Build job list --------------------------------------------
JOBFILE="$(mktemp)"
trap 'rm -f "$JOBFILE"' EXIT

while IFS=',' read -r label nVoLegacy nVoPedca nVi nBe nBk; do
  label="${label//$'\r'/}"; nBk="${nBk//$'\r'/}"
  [[ -z "$label" || "$label" == "scenarioLabel" || "$label" == \#* ]] && continue
  for v in "$nVoLegacy" "$nVoPedca" "$nVi" "$nBe" "$nBk"; do
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid count in scenario '$label'." >&2; exit 1; }
  done
  (( nVoLegacy + nVoPedca > 0 )) || { echo "ERROR: scenario '$label' has no VO stations." >&2; exit 1; }

  ap="$AP_PEDCA"
  if [[ "$CLEAN_BASELINE" == 1 && "$nVoPedca" == 0 ]]; then ap=0; fi

  for ampdu in $AMPDU_MODES; do
    for load in $LOADS; do
      for ((run=1; run<=NUM_RUNS; run++)); do
        tag="L${load}_D${ampdu}_${label}_run${run}"   # D1 = A-MPDU disabled
        out="$RAW_DIR/$tag.csv"
        if [[ -s "$out" && "$FORCE" != 1 ]]; then continue; fi
        rm -f "$out"
        args="--nBe=$nBe --nBk=$nBk --nVi=$nVi --nVoLegacy=$nVoLegacy --nVoPedca=$nVoPedca"
        args+=" --perStationLoadFixed=$PER_STATION_LOAD_FIXED --perAcLoadMbps=$load"
        args+=" --perStationLoadMbpsFixed=$PER_STATION_LOAD_MBPS"
        args+=" --trafficModel=$TRAFFIC_MODEL --burstOnTime=$BURST_ON_TIME --burstOffMean=$BURST_OFF_MEAN"
        args+=" --preserveMeanLoad=$PRESERVE_MEAN_LOAD --payloadSize=$PAYLOAD_SIZE"
        args+=" --simulationTime=$SIM_TIME --warmupTime=$WARMUP_TIME --drainTime=$DRAIN_TIME"
        args+=" --bssRadius=$BSS_RADIUS --disableAmpdu=$ampdu"
        args+=" --pedcaQsrcThreshold=$PEDCA_QSRC_THR --pedcaPsrcThreshold=$PEDCA_PSRC_THR"
        args+=" --pedcaDsAifsn=$PEDCA_DS_AIFSN --pedcaCwDs=$PEDCA_CW_DS"
        args+=" --pedcaStage2Aifsn=$PEDCA_STAGE2_AIFSN --pedcaStage2CwMin=$PEDCA_STAGE2_CWMIN"
        args+=" --pedcaStage2CwMax=$PEDCA_STAGE2_CWMAX --pedcaStage2WindowUs=$PEDCA_STAGE2_WINDOW_US"
        args+=" --apPedcaSupported=$ap --sameContentMaxDelayNs=$SAME_CONTENT_MAX_DELAY_NS"
        args+=" --rngSeed=$RNG_SEED --rngRun=$run --enablePcap=$ENABLE_PCAP --pcapDirectory=$PCAP_DIRECTORY"
        [[ -n "$DATA_MODE" ]] && args+=" --dataMode=$DATA_MODE"
        [[ -n "$PHY_DATA_RATE_MBPS" ]] && args+=" --phyDataRateMbps=$PHY_DATA_RATE_MBPS"
        [[ -n "$QUEUE_MAX_DELAY_MS" ]] && args+=" --queueMaxDelayMs=$QUEUE_MAX_DELAY_MS"
        [[ -n "$EXTRA_ARGS" ]] && args+=" $EXTRA_ARGS"
        args+=" --scenarioLabel=${label}_seed${RNG_SEED}_run${run} --outputCsv=$out"
        printf '%s\t%s\n' "$tag" "$args" >> "$JOBFILE"
      done
    done
  done
done < <(tail -n +2 "$SCENARIOS_CSV" | tr -d '\r')

sort -u -t$'\t' -k1,1 -s "$JOBFILE" > "$JOBFILE.u" && mv "$JOBFILE.u" "$JOBFILE"
TOTAL=$(wc -l < "$JOBFILE" | tr -d ' ')
echo "=============================================================="
echo "Program: $PROGRAM   Scenarios: $SCENARIOS_CSV"
echo "Loads (Mbps/AC): $LOADS   A-MPDU disabled flags: $AMPDU_MODES"
echo "Runs/point: $NUM_RUNS   Seed: $RNG_SEED   Jobs: $JOBS   Traffic: $TRAFFIC_MODEL"
echo "Runs to execute: $TOTAL (finished runs skipped unless --force)"
echo "Output: $RAW_DIR"
echo "=============================================================="
[[ "$TOTAL" -gt 0 ]] || { echo "Nothing to do."; exit 0; }

FAILED="$OUT_DIR/failed_runs.txt"; : > "$FAILED"
LOGDIR="$OUT_DIR/logs"; mkdir -p "$LOGDIR"

run_one() {
  local tag="$1" args="$2"
  rm -f "$RAW_DIR/$tag.csv"   # the simulator APPENDS to its CSV: always start clean
  if ./ns3 run --no-build "$PROGRAM $args" > "$LOGDIR/$tag.log" 2>&1 < /dev/null; then
    echo "done: $tag"
  else
    echo "FAILED: $tag (see $LOGDIR/$tag.log)" | tee -a "$FAILED" >&2
    rm -f "$RAW_DIR/$tag.csv"
  fi
}

n=0
while IFS=$'\t' read -r -u 3 tag args; do
  run_one "$tag" "$args" < /dev/null &
  n=$((n+1))
  if (( n % JOBS == 0 )); then wait; fi
done 3< "$JOBFILE"
wait

if [[ -s "$FAILED" ]]; then
  echo "Some runs failed: $FAILED (re-run the script to retry only those)" >&2
  exit 1
fi
echo "Finished. Analyse with: python3 analyse_pedca.py $RAW_DIR --out $OUT_DIR/analysis"
