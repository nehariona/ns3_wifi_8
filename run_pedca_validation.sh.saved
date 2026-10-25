#!/usr/bin/env bash
# run_pedca_validation.sh - small P-EDCA validation runs with debug logging (UNTESTED helper).
#
# Needs a debug build (./ns3 configure -d debug --enable-logs) so that NS_LOG_DEBUG is compiled in.
#
#   T2: several P-EDCA STAs, CWds=0  -> DS-CTS frames from different STAs should share one uid and
#                                      start within the same slot; Stage 2 entered by all of them
#   T6: PSRC threshold 2             -> a Stage 2 loser should account PSRC/QSRC exactly once per
#                                      round and, while eligible, send another DS-CTS
#
# Usage: ./run_pedca_validation.sh [nVoPedca] [simTimeSeconds]
set -euo pipefail

N_PEDCA="${1:-3}"
SIM_TIME="${2:-1}"
OUT_DIR="results/pedca_validation"
mkdir -p "${OUT_DIR}"

export NS_LOG="QosTxop=level_debug|prefix_time|prefix_node:QosFrameExchangeManager=level_debug|prefix_time|prefix_node:WifiPhy=level_debug|prefix_time|prefix_node:PhyEntity=level_debug|prefix_time|prefix_node"

run_case() {
    local tag="$1"; shift
    local log="${OUT_DIR}/${tag}.log"
    echo "=== ${tag} -> ${log}"
    ./ns3 run "scratch/pedca-final --nVoLegacy=0 --nVoPedca=${N_PEDCA} --nVi=0 --nBe=0 --nBk=0 \
        --simulationTime=${SIM_TIME} --pedcaCwDs=0 --pedcaDsAifsn=2 --outputCsv=${OUT_DIR}/${tag}.csv $*" \
        > "${log}" 2>&1 || echo "run failed, see ${log}"
}

run_case T2_simultaneous_dscts --pedcaPsrcThreshold=1
run_case T6_stage2_loss        --pedcaPsrcThreshold=2

for f in "${OUT_DIR}"/T2_simultaneous_dscts.log "${OUT_DIR}"/T6_stage2_loss.log; do
    echo "--- $(basename "$f")"
    echo "DS-CTS transmissions:       $(grep -c 'P-EDCA DS-CTS TX' "$f" || true)"
    echo "DS-CTS TX with effCw != 0:  $(grep 'P-EDCA DS-CTS TX' "$f" | grep -vc 'effCw=0 ' || true)"
    echo "Distinct DS-CTS uids:       $(grep 'P-EDCA DS-CTS TX' "$f" | sed -E 's/.*uid=([0-9]+).*/\1/' | sort -u | wc -l)"
    echo "Same-content combines:      $(grep -c 'combined, arrival offset' "$f" || true)"
    echo "Stage 2 entries/exits:      $(grep -c 'Enter P-EDCA Stage 2' "$f" || true) / $(grep -c 'Exit P-EDCA Stage 2' "$f" || true)"
    echo "Stage 2 losses accounted:   $(grep -c 'Lost P-EDCA contention' "$f" || true)"
done
