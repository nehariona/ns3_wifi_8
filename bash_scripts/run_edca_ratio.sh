#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# EDCA station-ratio experiment driver
#
# Reads scenario definitions (scenarioLabel,nVo,nVi,nBe,nBk) from a CSV file
# and runs each one across NUM_RUNS independent RngRun replicates, holding
# RngSeed fixed (per ns-3's recommended replication methodology).
#
# Load policy: fixed PER-AC load (perAcLoadMbps), so total demand per AC
# stays constant across scenarios regardless of how many stations share it.
# This isolates the effect of station-count ratio from traffic-volume
# effects. Pass --per-station-load to switch policy (see usage below).
# ==============================================================================

SCENARIOS_CSV="ratio_scenarios.csv"
OUTPUT_CSV="results/edca_ratio.csv"

NUM_RUNS=10
RNG_SEED=1

PER_AC_LOAD_MBPS=2
PAYLOAD_SIZE=1024
SIM_TIME=60
WARMUP_TIME=5
DRAIN_TIME=5
BSS_RADIUS=5

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
tail -n +2 "$SCENARIOS_CSV" | while IFS=',' read -r label nVo nVi nBe nBk; do

    # Skip blank lines
    [[ -z "$label" ]] && continue

    total=$((nVo + nVi + nBe + nBk))

    echo "=== Scenario: ${label}  (VO=${nVo} VI=${nVi} BE=${nBe} BK=${nBk}, N=${total}) ==="

    for run in $(seq 1 "$NUM_RUNS"); do

        echo "  -- RngRun: ${run} --"

        ./ns3 run "scratch/edca-ratio-validation \
            --nBe=${nBe} \
            --nBk=${nBk} \
            --nVi=${nVi} \
            --nVo=${nVo} \
            --perAcLoadMbps=${PER_AC_LOAD_MBPS} \
            ${LOAD_POLICY_FLAG} \
            --payloadSize=${PAYLOAD_SIZE} \
            --simulationTime=${SIM_TIME} \
            --warmupTime=${WARMUP_TIME} \
            --drainTime=${DRAIN_TIME} \
            --bssRadius=${BSS_RADIUS} \
            --rngSeed=${RNG_SEED} \
            --rngRun=${run} \
            --enablePcap=0 \
            --scenarioLabel=${label} \
            --outputCsv=${OUTPUT_CSV}"

    done

done

echo "Done. Results in ${OUTPUT_CSV}"
