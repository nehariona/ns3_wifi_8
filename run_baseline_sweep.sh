#!/usr/bin/env bash
set -euo pipefail

NUM_STATIONS=(4 8 12 16 20 24)

OFFERED_LOAD_MBPS=8
PAYLOAD_SIZE=1024
SIM_TIME=60
WARMUP_TIME=5
DRAIN_TIME=5

OUTPUT_CSV="results/edca_baseline.csv"

mkdir -p results
rm -f "$OUTPUT_CSV"

for n in "${NUM_STATIONS[@]}"; do
    for run in $(seq 1 10); do

        echo "=== Stations: ${n}, RngRun: ${run} ==="

        ./ns3 run "scratch/edca-baseline-validation \
            --numStations=${n} \
            --offeredLoadMbps=${OFFERED_LOAD_MBPS} \
            --payloadSize=${PAYLOAD_SIZE} \
            --simulationTime=${SIM_TIME} \
            --warmupTime=${WARMUP_TIME} \
            --drainTime=${DRAIN_TIME} \
            --rngRun=${run} \
            --enablePcap=0 \
            --outputCsv=${OUTPUT_CSV}"

    done
done

echo "Done. Results in ${OUTPUT_CSV}"
