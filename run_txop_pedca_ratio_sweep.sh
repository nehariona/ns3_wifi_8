#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# P-EDCA ratio sweep driver (Poisson-burst traffic, fixed 2 Mbit/s per AC)
#
# Reads scenarios (scenarioLabel,nVoLegacy,nVoPedca,nVi,nBe,nBk) from a CSV
# and runs each one for NUM_RUNS RngRun replicates with a fixed RngSeed.
#
# Load policy: fixed PER-AC load. Every AC's long-run mean offered load is
# PER_AC_LOAD_MBPS (2 Mbit/s), split evenly across that AC's stations.
# With Poisson-burst traffic and PRESERVE_MEAN_LOAD=1 each station sends at
# (on+off)/on x its share while ON, so the mean stays at 2 Mbit/s per AC.
#
# Usage: ./run_pedca_ratio_sweep.sh [--scenarios FILE] [--runs N] [--seed N]
#                                   [--output FILE] [--traffic poissonBurst|cbr]
# Run from the ns-3 root directory (where ./ns3 is).
# ==============================================================================

SCENARIOS_CSV="pedca_ratio_scenarios.csv"
OUTPUT_CSV="results/pedca_ratio_poisson_burst.csv"

NUM_RUNS=1
RNG_SEED=1

# ---- Load: fixed per AC -------------------------------------------------------
PER_AC_LOAD_MBPS=10

# ---- Traffic ------------------------------------------------------------------
TRAFFIC_MODEL="poissonBurst"
BURST_ON_TIME=1.0        # s, fixed burst length
BURST_OFF_MEAN=2.0       # s, mean of the exponential gap between bursts
PRESERVE_MEAN_LOAD=1     # 1: long-run mean = PER_AC_LOAD_MBPS per AC

PAYLOAD_SIZE=1024
SIM_TIME=60
WARMUP_TIME=5
DRAIN_TIME=5
BSS_RADIUS=5

# ---- P-EDCA parameters (patch v3 defaults; verify against your draft) ---------
PEDCA_QSRC_THR=1
PEDCA_PSRC_THR=4
PEDCA_DS_AIFSN=2
PEDCA_CW_DS=7
PEDCA_STAGE2_AIFSN=2
PEDCA_STAGE2_CWMIN=3
PEDCA_STAGE2_CWMAX=7
PEDCA_STAGE2_WINDOW_US=0     # 0 = computed (97 us with the values above)
AP_PEDCA=1                   # needed for the AP to answer Stage-2 RTS
SAME_CONTENT_MAX_DELAY_NS=800

usage() {
    echo "Usage: $0 [--scenarios FILE] [--runs N] [--seed N] [--output FILE] [--traffic poissonBurst|cbr]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenarios) SCENARIOS_CSV="$2"; shift 2 ;;
        --runs) NUM_RUNS="$2"; shift 2 ;;
        --seed) RNG_SEED="$2"; shift 2 ;;
        --output) OUTPUT_CSV="$2"; shift 2 ;;
        --traffic) TRAFFIC_MODEL="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if [[ ! -x ./ns3 ]]; then
    echo "Run this from the ns-3 root directory (./ns3 not found)"
    exit 1
fi

if [[ ! -f "$SCENARIOS_CSV" ]]; then
    echo "Scenario file not found: ${SCENARIOS_CSV}"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_CSV")"

if [[ -f "$OUTPUT_CSV" ]]; then
    backup="${OUTPUT_CSV%.csv}_$(date +%Y%m%d_%H%M%S).csv"
    mv "$OUTPUT_CSV" "$backup"
    echo "Existing results moved to ${backup}"
fi

echo "Load: ${PER_AC_LOAD_MBPS} Mbit/s per AC (mean), traffic=${TRAFFIC_MODEL}, runs=${NUM_RUNS}, seed=${RNG_SEED}"

# Skip header line; tr strips Windows line endings if the CSV was edited on Windows
tail -n +2 "$SCENARIOS_CSV" | tr -d '\r' | while IFS=',' read -r label nVoLegacy nVoPedca nVi nBe nBk; do

    [[ -z "$label" ]] && continue

    total=$((nVoLegacy + nVoPedca + nVi + nBe + nBk))

    echo "=== ${label}  (BE=${nBe} BK=${nBk} VI=${nVi} VO_LEGACY=${nVoLegacy} VO_PEDCA=${nVoPedca}, N=${total}) ==="

    for run in $(seq 1 "$NUM_RUNS"); do

        echo "  -- RngRun ${run}/${NUM_RUNS} --"

        ./ns3 run "scratch/pedca-txop-ratio-sweep \
            --nBe=${nBe} \
            --nBk=${nBk} \
            --nVi=${nVi} \
            --nVoLegacy=${nVoLegacy} \
            --nVoPedca=${nVoPedca} \
            --perStationLoadFixed=0 \
            --perAcLoadMbps=${PER_AC_LOAD_MBPS} \
            --trafficModel=${TRAFFIC_MODEL} \
            --burstOnTime=${BURST_ON_TIME} \
            --burstOffMean=${BURST_OFF_MEAN} \
            --preserveMeanLoad=${PRESERVE_MEAN_LOAD} \
            --payloadSize=${PAYLOAD_SIZE} \
            --simulationTime=${SIM_TIME} \
            --warmupTime=${WARMUP_TIME} \
            --drainTime=${DRAIN_TIME} \
            --bssRadius=${BSS_RADIUS} \
            --pedcaQsrcThreshold=${PEDCA_QSRC_THR} \
            --pedcaPsrcThreshold=${PEDCA_PSRC_THR} \
            --pedcaDsAifsn=${PEDCA_DS_AIFSN} \
            --pedcaCwDs=${PEDCA_CW_DS} \
            --pedcaStage2Aifsn=${PEDCA_STAGE2_AIFSN} \
            --pedcaStage2CwMin=${PEDCA_STAGE2_CWMIN} \
            --pedcaStage2CwMax=${PEDCA_STAGE2_CWMAX} \
            --pedcaStage2WindowUs=${PEDCA_STAGE2_WINDOW_US} \
            --apPedcaSupported=${AP_PEDCA} \
            --sameContentMaxDelayNs=${SAME_CONTENT_MAX_DELAY_NS} \
            --rngSeed=${RNG_SEED} \
            --rngRun=${run} \
            --enablePcap=0 \
            --scenarioLabel=${label} \
            --outputCsv=${OUTPUT_CSV}" > /dev/null

    done
done

echo "Done. Results in ${OUTPUT_CSV}"
