#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# P-EDCA adoption-ratio experiment driver
#
# Reads scenario definitions (scenarioLabel,nVoLegacy,nVoPedca,nVi,nBe,nBk)
# from a CSV file and runs each one across NUM_RUNS independent RngRun
# replicates, holding RngSeed fixed (per ns-3's recommended replication
# methodology).
#
# Load policy: fixed PER-AC load (perAcLoadMbps). AC_VO's combined total
# demand across BOTH sub-groups stays constant across scenarios regardless
# of the legacy/P-EDCA split, isolating the effect of adoption ratio from
# traffic-volume effects. Pass --per-station-load to switch policy (see
# usage below).
#
# P-EDCA tuning parameters (QSRC/PSRC thresholds, DS-CTS and Stage-2
# contention parameters) are fixed constants for the whole sweep here;
# pass them through as extra flags if you want per-scenario values instead.
# ==============================================================================

SCENARIOS_CSV="pedca_ratio_scenarios.csv"
OUTPUT_CSV="results/pedca_ratio.csv"

NUM_RUNS=10
RNG_SEED=1

PER_AC_LOAD_MBPS=2
PAYLOAD_SIZE=1024
SIM_TIME=60
WARMUP_TIME=5
DRAIN_TIME=5
BSS_RADIUS=5

# P-EDCA parameters, fixed for the whole sweep. Verify every one of these
# against your target 802.11bn draft before publishing results -- see the
# comments in qos-txop.cc / the scenario .cc file for what's confirmed vs.
# assumed.
PEDCA_QSRC_THR=1
PEDCA_PSRC_THR=1
PEDCA_DS_AIFSN=1
PEDCA_CW_DS=7          # NOT 3: the draft reserves 3, see qos-txop.cc comment
PEDCA_STAGE2_AIFSN=1
PEDCA_STAGE2_CWMIN=3
PEDCA_STAGE2_CWMAX=7
PEDCA_STAGE2_WINDOW_US=97

LOAD_POLICY_FLAG="--perStationLoadFixed=0"

usage() {
    echo "Usage: $0 [--scenarios FILE] [--runs N] [--seed N] [--per-station-load]"
    echo "  --scenarios FILE     Path to scenario CSV (default: ${SCENARIOS_CSV})"
    echo "  --runs N              Number of RngRun replicates per scenario (default: ${NUM_RUNS})"
    echo "  --seed N              Fixed RngSeed value (default: ${RNG_SEED})"
    echo "  --per-station-load    Fix load per STATION instead of per AC"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenarios) SCENARIOS_CSV="$2"; shift 2 ;;
        --runs) NUM_RUNS="$2"; shift 2 ;;
        --seed) RNG_SEED="$2"; shift 2 ;;
        --per-station-load) LOAD_POLICY_FLAG="--perStationLoadFixed=1"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if [[ ! -f "$SCENARIOS_CSV" ]]; then
    echo "Scenario file not found: ${SCENARIOS_CSV}"
    exit 1
fi

mkdir -p results
rm -f "$OUTPUT_CSV"

# Skip header line, then read each scenario row.
tail -n +2 "$SCENARIOS_CSV" | while IFS=',' read -r label nVoLegacy nVoPedca nVi nBe nBk; do

    # Skip blank lines
    [[ -z "$label" ]] && continue

    nVoTotal=$((nVoLegacy + nVoPedca))
    total=$((nVoTotal + nVi + nBe + nBk))

    echo "=== Scenario: ${label}  (VO_LEGACY=${nVoLegacy} VO_PEDCA=${nVoPedca} VI=${nVi} BE=${nBe} BK=${nBk}, N=${total}) ==="

    for run in $(seq 1 "$NUM_RUNS"); do

        echo "  -- RngRun: ${run} --"

        ./ns3 run "scratch/pedca-ratio-validation \
            --nBe=${nBe} \
            --nBk=${nBk} \
            --nVi=${nVi} \
            --nVoLegacy=${nVoLegacy} \
            --nVoPedca=${nVoPedca} \
            --perAcLoadMbps=${PER_AC_LOAD_MBPS} \
            ${LOAD_POLICY_FLAG} \
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
            --rngSeed=${RNG_SEED} \
            --rngRun=${run} \
            --enablePcap=0 \
            --scenarioLabel=${label} \
            --outputCsv=${OUTPUT_CSV}"

    done

done

echo "Done. Results in ${OUTPUT_CSV}"