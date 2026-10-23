#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# P-EDCA adoption / parameter sweep for ns-3.48
#
# Required target:
#   scratch/pedca-txop-ratio-sweep
#
# Scenario CSV columns:
#   scenarioLabel,nVoLegacy,nVoPedca,nVi,nBe,nBk
#
# Usage examples:
#   ./run_pedca_ratio_sweep.sh
#   ./run_pedca_ratio_sweep.sh --runs 5 --seed 10
#   ./run_pedca_ratio_sweep.sh --traffic cbr --load 5
#   ./run_pedca_ratio_sweep.sh --traffic poissonBurst --load 10 \
#       --sim-time 120 --runs 5
#   ./run_pedca_ratio_sweep.sh --help
# ================================================================

# ---- Paths ------------------------------------------------------
SCENARIO_PROGRAM="${SCENARIO_PROGRAM:-scratch/pedca-txop-ratio-sweep}"
SCENARIOS_CSV="${SCENARIOS_CSV:-pedca_ratio_scenarios.csv}"
OUTPUT_CSV="${OUTPUT_CSV:-results/pedca_adoption.csv}"

# ---- Randomness -------------------------------------------------
NUM_RUNS="${NUM_RUNS:-1}"
RNG_SEED="${RNG_SEED:-1}"

# ---- Traffic / offered load ------------------------------------
TRAFFIC_MODEL="${TRAFFIC_MODEL:-poissonBurst}"
PER_AC_LOAD_MBPS="${PER_AC_LOAD_MBPS:-10}"
PER_STATION_LOAD_FIXED="${PER_STATION_LOAD_FIXED:-0}"
PER_STATION_LOAD_MBPS="${PER_STATION_LOAD_MBPS:-0.25}"

BURST_ON_TIME="${BURST_ON_TIME:-1.0}"
BURST_OFF_MEAN="${BURST_OFF_MEAN:-2.0}"
PRESERVE_MEAN_LOAD="${PRESERVE_MEAN_LOAD:-1}"

# ---- Simulation -------------------------------------------------
PAYLOAD_SIZE="${PAYLOAD_SIZE:-1024}"
SIM_TIME="${SIM_TIME:-60}"
WARMUP_TIME="${WARMUP_TIME:-5}"
DRAIN_TIME="${DRAIN_TIME:-5}"
BSS_RADIUS="${BSS_RADIUS:-5}"

# ---- P-EDCA parameters -----------------------------------------
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

# ---- Other settings --------------------------------------------
ENABLE_PCAP="${ENABLE_PCAP:-0}"
PCAP_DIRECTORY="${PCAP_DIRECTORY:-results/pcap}"
BACKUP_EXISTING="${BACKUP_EXISTING:-1}"

usage() {
    cat <<'EOF'
Usage:
  ./run_pedca_ratio_sweep.sh [options]

Experiment options:
  --scenarios FILE       Scenario CSV
  --output FILE          Combined results CSV
  --runs N               Number of RngRun replicates per scenario
  --seed N               Fixed RngSeed
  --program NAME         ns-3 scratch target

Traffic options:
  --traffic NAME         poissonBurst or cbr (if supported by C++)
  --load Mbps            Fixed total offered load per AC
  --per-station-fixed N  0 = fixed per-AC load; 1 = fixed per-station load
  --station-load Mbps    Per-station load when per-station mode is enabled
  --burst-on SEC         Burst ON duration
  --burst-off SEC        Mean exponential OFF duration
  --preserve-mean N      Preserve mean offered load for burst traffic

Simulation options:
  --payload BYTES        UDP payload size
  --sim-time SEC         Measurement duration
  --warmup SEC           Warm-up duration
  --drain SEC            Drain duration after traffic
  --radius METRES        BSS placement radius

P-EDCA options:
  --qsrc-threshold N
  --psrc-threshold N
  --ds-aifsn N
  --cw-ds N
  --stage2-aifsn N
  --stage2-cwmin N
  --stage2-cwmax N
  --stage2-window-us N   0 means computed, if supported by C++
  --ap-pedca N           AP P-EDCA support: 0 or 1
  --same-content-delay-ns N

Other:
  --pcap N               Enable PCAP: 0 or 1
  --pcap-dir DIR         PCAP directory
  --no-backup            Do not back up existing output CSV
  -h, --help             Show help

Environment variables with corresponding uppercase names can also
set the defaults. CLI options override environment variables.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenarios) SCENARIOS_CSV="$2"; shift 2 ;;
        --output) OUTPUT_CSV="$2"; shift 2 ;;
        --runs) NUM_RUNS="$2"; shift 2 ;;
        --seed) RNG_SEED="$2"; shift 2 ;;
        --program) SCENARIO_PROGRAM="$2"; shift 2 ;;

        --traffic) TRAFFIC_MODEL="$2"; shift 2 ;;
        --load) PER_AC_LOAD_MBPS="$2"; shift 2 ;;
        --per-station-fixed) PER_STATION_LOAD_FIXED="$2"; shift 2 ;;
        --station-load) PER_STATION_LOAD_MBPS="$2"; shift 2 ;;
        --burst-on) BURST_ON_TIME="$2"; shift 2 ;;
        --burst-off) BURST_OFF_MEAN="$2"; shift 2 ;;
        --preserve-mean) PRESERVE_MEAN_LOAD="$2"; shift 2 ;;

        --payload) PAYLOAD_SIZE="$2"; shift 2 ;;
        --sim-time) SIM_TIME="$2"; shift 2 ;;
        --warmup) WARMUP_TIME="$2"; shift 2 ;;
        --drain) DRAIN_TIME="$2"; shift 2 ;;
        --radius) BSS_RADIUS="$2"; shift 2 ;;

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
        --no-backup) BACKUP_EXISTING=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

# ---- Validate basic settings -----------------------------------
if [[ ! -x ./ns3 ]]; then
    echo "ERROR: Run this script from the ns-3 root directory." >&2
    exit 1
fi

if [[ ! -f "$SCENARIOS_CSV" ]]; then
    echo "ERROR: Scenario file not found: $SCENARIOS_CSV" >&2
    exit 1
fi

if [[ ! "$NUM_RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --runs must be a positive integer." >&2
    exit 1
fi

if [[ ! "$RNG_SEED" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --seed must be a positive integer." >&2
    exit 1
fi

if [[ "$TRAFFIC_MODEL" != "poissonBurst" &&
      "$TRAFFIC_MODEL" != "cbr" ]]; then
    echo "ERROR: This script documents traffic choices poissonBurst or cbr." >&2
    echo "Use only traffic names actually implemented by your C++ scenario." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_CSV")"
mkdir -p "$PCAP_DIRECTORY"

if [[ -s "$OUTPUT_CSV" ]]; then
    if [[ "$BACKUP_EXISTING" == "1" ]]; then
        backup="${OUTPUT_CSV%.csv}_$(date +%Y%m%d_%H%M%S).csv"
        mv "$OUTPUT_CSV" "$backup"
        echo "Existing output backed up to: $backup"
    else
        echo "ERROR: Output already exists: $OUTPUT_CSV" >&2
        echo "Choose a new --output path or omit --no-backup." >&2
        exit 1
    fi
fi

echo "=============================================================="
echo "P-EDCA Adoption / Parameter Sweep"
echo "Program:             $SCENARIO_PROGRAM"
echo "Scenarios:           $SCENARIOS_CSV"
echo "Output:              $OUTPUT_CSV"
echo "Traffic:             $TRAFFIC_MODEL"
echo "Load per AC:         $PER_AC_LOAD_MBPS Mbps"
echo "Per-station mode:    $PER_STATION_LOAD_FIXED"
echo "Runs per scenario:   $NUM_RUNS"
echo "RngSeed:             $RNG_SEED"
echo "Simulation:          $SIM_TIME s"
echo "Warm-up / drain:     $WARMUP_TIME / $DRAIN_TIME s"
echo "Payload:             $PAYLOAD_SIZE bytes"
echo "=============================================================="

# Read CSV while preserving the caller's shell and error handling.
# CSV must be a simple comma-separated file without quoted commas.
while IFS=',' read -r label nVoLegacy nVoPedca nVi nBe nBk; do
    label="${label//$'\r'/}"
    nVoLegacy="${nVoLegacy//$'\r'/}"
    nVoPedca="${nVoPedca//$'\r'/}"
    nVi="${nVi//$'\r'/}"
    nBe="${nBe//$'\r'/}"
    nBk="${nBk//$'\r'/}"

    [[ -z "$label" || "$label" == "scenarioLabel" || "$label" == \#* ]] && continue

    for value in "$nVoLegacy" "$nVoPedca" "$nVi" "$nBe" "$nBk"; do
        if [[ ! "$value" =~ ^[0-9]+$ ]]; then
            echo "ERROR: Invalid station count in scenario '$label'." >&2
            exit 1
        fi
    done

    if (( nVoLegacy + nVoPedca == 0 )); then
        echo "ERROR: Scenario '$label' has zero VO stations." >&2
        exit 1
    fi

    total=$((nVoLegacy + nVoPedca + nVi + nBe + nBk))

    echo
    echo "=== $label ==="
    echo "VO legacy=$nVoLegacy, VO P-EDCA=$nVoPedca, VI=$nVi, BE=$nBe, BK=$nBk, total=$total"

    for ((run=1; run<=NUM_RUNS; run++)); do
        echo "--- RngRun $run / $NUM_RUNS ---"

        # Do not redirect all output to /dev/null: errors must remain visible.
        ./ns3 run "$SCENARIO_PROGRAM \
            --nBe=$nBe \
            --nBk=$nBk \
            --nVi=$nVi \
            --nVoLegacy=$nVoLegacy \
            --nVoPedca=$nVoPedca \
            --perStationLoadFixed=$PER_STATION_LOAD_FIXED \
            --perAcLoadMbps=$PER_AC_LOAD_MBPS \
            --perStationLoadMbpsFixed=$PER_STATION_LOAD_MBPS \
            --trafficModel=$TRAFFIC_MODEL \
            --burstOnTime=$BURST_ON_TIME \
            --burstOffMean=$BURST_OFF_MEAN \
            --preserveMeanLoad=$PRESERVE_MEAN_LOAD \
            --payloadSize=$PAYLOAD_SIZE \
            --simulationTime=$SIM_TIME \
            --warmupTime=$WARMUP_TIME \
            --drainTime=$DRAIN_TIME \
            --bssRadius=$BSS_RADIUS \
            --pedcaQsrcThreshold=$PEDCA_QSRC_THR \
            --pedcaPsrcThreshold=$PEDCA_PSRC_THR \
            --pedcaDsAifsn=$PEDCA_DS_AIFSN \
            --pedcaCwDs=$PEDCA_CW_DS \
            --pedcaStage2Aifsn=$PEDCA_STAGE2_AIFSN \
            --pedcaStage2CwMin=$PEDCA_STAGE2_CWMIN \
            --pedcaStage2CwMax=$PEDCA_STAGE2_CWMAX \
            --pedcaStage2WindowUs=$PEDCA_STAGE2_WINDOW_US \
            --apPedcaSupported=$AP_PEDCA \
            --sameContentMaxDelayNs=$SAME_CONTENT_MAX_DELAY_NS \
            --rngSeed=$RNG_SEED \
            --rngRun=$run \
            --enablePcap=$ENABLE_PCAP \
            --pcapDirectory=$PCAP_DIRECTORY \
            --scenarioLabel=${label}_seed${RNG_SEED}_run${run} \
            --outputCsv=$OUTPUT_CSV"
    done
done < <(tail -n +2 "$SCENARIOS_CSV" | tr -d '\r')

echo
echo "Finished. Results: $OUTPUT_CSV"
