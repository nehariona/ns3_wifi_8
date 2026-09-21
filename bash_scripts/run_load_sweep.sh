#!/usr/bin/env bash
set -euo pipefail

NUM_STATIONS=(12)
OFFERED_LOADS_MBPS=(1 2 4 6 8 10 12 24 100)

PAYLOAD_SIZE=1024
SIM_TIME=60
WARMUP_TIME=5
DRAIN_TIME=5

OUTPUT_CSV="results/edca_load_sweep.csv"

mkdir -p results
rm -f "$OUTPUT_CSV"

for n in "${NUM_STATIONS[@]}"; do
    for load in "${OFFERED_LOADS_MBPS[@]}"; do
        for run in $(seq 1 10); do

            echo "=== Stations: ${n}, Load: ${load} Mbps, RngRun: ${run} ==="

            ./ns3 run "scratch/edca-baseline-validation \
                --numStations=${n} \
                --offeredLoadMbps=${load} \
                --payloadSize=${PAYLOAD_SIZE} \
                --simulationTime=${SIM_TIME} \
                --warmupTime=${WARMUP_TIME} \
                --drainTime=${DRAIN_TIME} \
                --rngRun=${run} \
                --enablePcap=0 \
                --outputCsv=${OUTPUT_CSV}"

        done
    done
done

echo "Done. Results in ${OUTPUT_CSV}"
