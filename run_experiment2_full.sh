
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Experiment 2: P-EDCA load sweep
# 3 seeds x 2 repetitions x 3 traffic x 2 adoption x 5 loads
# Total = 180 simulations
# ============================================================

OUTPUT_DIR="results/exp2"
OUTPUT_CSV="${OUTPUT_DIR}/summary/exp2.csv"
PROGRAM="scratch/pedca-txop-ratio-sweep"

NUM_SEEDS=3
REPETITIONS=2
RNG_SEED=1
JOBS=8
DRY=0

LOADS_MBPS="3 6 12 24 48"
TRAFFIC_MODELS="cbr poisson poissonBurst"
ADOPTION_LIST="0 100"

N_VO_TOTAL=20
N_VI=4
N_BE=4
N_BK=4

BURST_ON_TIME=1.0
BURST_OFF_MEAN=2.0
PRESERVE_MEAN_LOAD=1

PAYLOAD_SIZE=1024
SIM_TIME=300
WARMUP_TIME=5
DRAIN_TIME=5
BSS_RADIUS=5
DELAY_BIN_WIDTH_US=10

PEDCA_QSRC_THR=3
PEDCA_PSRC_THR=4
PEDCA_DS_AIFSN=2
PEDCA_CW_DS=0
PEDCA_STAGE2_AIFSN=2
PEDCA_STAGE2_CWMIN=3
PEDCA_STAGE2_CWMAX=7
PEDCA_STAGE2_WINDOW_US=0
AP_PEDCA=1
SAME_CONTENT_MAX_DELAY_NS=800

usage() {
    cat <<EOF
Usage: $0 [--seeds N] [--repetitions N] [--seed N]
          [--jobs N] [--output-dir DIR]
          [--adoption "0 100"] [--program scratch/NAME] [--dry]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --seeds) NUM_SEEDS="$2"; shift 2 ;;
        --repetitions) REPETITIONS="$2"; shift 2 ;;
        --seed) RNG_SEED="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --output-dir)
            OUTPUT_DIR="$2"
            OUTPUT_CSV="${OUTPUT_DIR}/summary/exp2.csv"
            shift 2 ;;
        --adoption) ADOPTION_LIST="$2"; shift 2 ;;
        --program) PROGRAM="$2"; shift 2 ;;
        --dry) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

if [[ ! -x ./ns3 ]]; then
    echo "ERROR: Run this script from the ns-3 root directory."
    exit 1
fi

if (( NUM_SEEDS < 1 || REPETITIONS < 1 || JOBS < 1 )); then
    echo "ERROR: Seeds, repetitions, and jobs must be positive."
    exit 1
fi

TOTAL_STAS=$((N_VO_TOTAL + N_VI + N_BE + N_BK))

# Make a unique directory for every experiment execution.
# Existing results are never deleted or overwritten.
RUN_ID="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${OUTPUT_DIR}/run_${RUN_ID}"
RAW_DIR="${RUN_DIR}/raw"
LOG_DIR="${RUN_DIR}/logs"
SUMMARY_DIR="${RUN_DIR}/summary"

mkdir -p "$RAW_DIR" "$LOG_DIR" "$SUMMARY_DIR"
OUTPUT_CSV="${SUMMARY_DIR}/exp2.csv"

echo "Building ns-3 ..."
./ns3 build > "${LOG_DIR}/build.log" 2>&1 || {
    echo "Build failed. See ${LOG_DIR}/build.log"
    exit 1
}

export OUTPUT_DIR RUN_DIR RAW_DIR LOG_DIR SUMMARY_DIR
export PROGRAM NUM_SEEDS REPETITIONS RNG_SEED JOBS
export LOADS_MBPS TRAFFIC_MODELS ADOPTION_LIST
export N_VO_TOTAL N_VI N_BE N_BK
export BURST_ON_TIME BURST_OFF_MEAN PRESERVE_MEAN_LOAD
export PAYLOAD_SIZE SIM_TIME WARMUP_TIME DRAIN_TIME
export BSS_RADIUS DELAY_BIN_WIDTH_US
export PEDCA_QSRC_THR PEDCA_PSRC_THR PEDCA_DS_AIFSN PEDCA_CW_DS
export PEDCA_STAGE2_AIFSN PEDCA_STAGE2_CWMIN PEDCA_STAGE2_CWMAX
export PEDCA_STAGE2_WINDOW_US AP_PEDCA SAME_CONTENT_MAX_DELAY_NS
export DRY

if [[ "$DRY" == "1" ]]; then
    echo "DRY RUN: no simulations will be executed."
fi

python3 <<'PY'
import csv
import concurrent.futures
import itertools
import os
import shlex
import subprocess
import sys
from pathlib import Path

run_dir = Path(os.environ["RUN_DIR"])
raw_dir = Path(os.environ["RAW_DIR"])
log_dir = Path(os.environ["LOG_DIR"])
summary_dir = Path(os.environ["SUMMARY_DIR"])

program = os.environ["PROGRAM"]
num_seeds = int(os.environ["NUM_SEEDS"])
repetitions = int(os.environ["REPETITIONS"])
base_seed = int(os.environ["RNG_SEED"])
jobs = int(os.environ["JOBS"])

loads = os.environ["LOADS_MBPS"].split()
traffic_models = os.environ["TRAFFIC_MODELS"].split()
adoptions = [int(x) for x in os.environ["ADOPTION_LIST"].split()]

n_vo_total = int(os.environ["N_VO_TOTAL"])
n_vi = int(os.environ["N_VI"])
n_be = int(os.environ["N_BE"])
n_bk = int(os.environ["N_BK"])

def env_int(name):
    return int(os.environ[name])

def env_float(name):
    return float(os.environ[name])

configs = list(itertools.product(
    traffic_models, adoptions, loads,
    range(1, num_seeds + 1),
    range(1, repetitions + 1)
))

total = len(configs)
manifest_path = run_dir / "manifest.csv"
jobs_list = []

for index, (traffic, adoption, load, seed_id, rep) in enumerate(configs, 1):
    n_pedca = (n_vo_total * adoption + 50) // 100
    n_legacy = n_vo_total - n_pedca

    label = f"load_{load}_{traffic}_a{adoption}"
    stem = f"{index:04d}_{label}_seed{seed_id}_rep{rep}"
    csv_path = raw_dir / f"{stem}.csv"
    log_path = log_dir / f"{stem}.log"

    # Three distinct RNG seeds; two RNG run streams per seed.
    actual_seed = base_seed + seed_id - 1

    args = [
        f"--nBe={n_be}", f"--nBk={n_bk}", f"--nVi={n_vi}",
        f"--nVoLegacy={n_legacy}", f"--nVoPedca={n_pedca}",
        "--perStationLoadFixed=0", f"--perAcLoadMbps={load}",
        f"--trafficModel={traffic}",
        f"--burstOnTime={os.environ['BURST_ON_TIME']}",
        f"--burstOffMean={os.environ['BURST_OFF_MEAN']}",
        f"--preserveMeanLoad={os.environ['PRESERVE_MEAN_LOAD']}",
        f"--payloadSize={env_int('PAYLOAD_SIZE')}",
        f"--simulationTime={env_int('SIM_TIME')}",
        f"--warmupTime={env_int('WARMUP_TIME')}",
        f"--drainTime={env_int('DRAIN_TIME')}",
        f"--bssRadius={env_int('BSS_RADIUS')}",
        f"--delayBinWidthUs={env_int('DELAY_BIN_WIDTH_US')}",
        f"--pedcaQsrcThreshold={env_int('PEDCA_QSRC_THR')}",
        f"--pedcaPsrcThreshold={env_int('PEDCA_PSRC_THR')}",
        f"--pedcaDsAifsn={env_int('PEDCA_DS_AIFSN')}",
        f"--pedcaCwDs={env_int('PEDCA_CW_DS')}",
        f"--pedcaStage2Aifsn={env_int('PEDCA_STAGE2_AIFSN')}",
        f"--pedcaStage2CwMin={env_int('PEDCA_STAGE2_CWMIN')}",
        f"--pedcaStage2CwMax={env_int('PEDCA_STAGE2_CWMAX')}",
        f"--pedcaStage2WindowUs={env_int('PEDCA_STAGE2_WINDOW_US')}",
        f"--apPedcaSupported={env_int('AP_PEDCA')}",
        f"--sameContentMaxDelayNs={env_int('SAME_CONTENT_MAX_DELAY_NS')}",
        f"--rngSeed={actual_seed}", f"--rngRun={rep}",
        "--enablePcap=0",
        f"--scenarioLabel={label}_seed{seed_id}_rep{rep}",
        f"--outputCsv={csv_path}",
    ]

    command = ["./ns3", "run", "--no-build",
               f"{program} " + " ".join(shlex.quote(a) for a in args)]

    jobs_list.append({
        "index": index, "traffic": traffic, "adoption": adoption,
        "load_mbps": load, "seed_id": seed_id,
        "rng_seed": actual_seed, "rng_run": rep,
        "repetition": rep, "status": "PENDING",
        "csv": str(csv_path), "log": str(log_path),
        "command": command,
    })

fields = [
    "index", "traffic", "adoption", "load_mbps", "seed_id",
    "rng_seed", "rng_run", "repetition", "status", "csv", "log"
]

def save_manifest():
    with manifest_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for job in jobs_list:
            writer.writerow({key: job[key] for key in fields})

save_manifest()

print(f"Experiment directory: {run_dir}")
print(f"Configurations: {len(traffic_models)} traffic x "
      f"{len(adoptions)} adoption x {len(loads)} loads")
print(f"Seeds: {num_seeds}; repetitions per seed: {repetitions}")
print(f"Total simulations: {total}; parallel jobs: {jobs}")

if os.environ.get("DRY") == "1":
    print("Dry run: manifest created; simulations not started.")
    sys.exit(0)

def execute(job):
    print(f"[{job['index']}/{total}] START "
          f"{job['traffic']} load={job['load_mbps']} "
          f"adoption={job['adoption']} seed={job['seed_id']} "
          f"rep={job['repetition']}", flush=True)

    with open(job["log"], "w", encoding="utf-8") as log:
        result = subprocess.run(
            job["command"], stdout=log, stderr=subprocess.STDOUT
        )

    if result.returncode == 0 and Path(job["csv"]).is_file():
        job["status"] = "SUCCESS"
    else:
        job["status"] = "FAILED"

    save_manifest()
    print(f"[{job['index']}/{total}] {job['status']}", flush=True)
    return job["status"] == "SUCCESS"

# Each worker updates a distinct job; serialize manifest writes.
# The manifest is rewritten after all jobs complete below.
def execute_safe(job):
    with open(job["log"], "w", encoding="utf-8") as log:
        result = subprocess.run(
            job["command"], stdout=log, stderr=subprocess.STDOUT
        )
    job["status"] = (
        "SUCCESS" if result.returncode == 0
        and Path(job["csv"]).is_file() else "FAILED"
    )
    print(f"[{job['index']}/{total}] {job['status']} "
          f"{job['traffic']} load={job['load_mbps']} "
          f"adoption={job['adoption']} seed={job['seed_id']} "
          f"rep={job['repetition']}", flush=True)
    return job["status"] == "SUCCESS"

with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
    list(pool.map(execute_safe, jobs_list))

save_manifest()

successful = [j for j in jobs_list if j["status"] == "SUCCESS"]
failed = [j for j in jobs_list if j["status"] != "SUCCESS"]
csv_files = [Path(j["csv"]) for j in successful if Path(j["csv"]).is_file()]

if csv_files:
    with summary_dir.joinpath("exp2.csv").open(
        "w", encoding="utf-8", newline=""
    ) as out:
        header_written = False
        for path in csv_files:
            with path.open(encoding="utf-8", newline="") as src:
                reader = csv.reader(src)
                try:
                    header = next(reader)
                except StopIteration:
                    continue
                if not header_written:
                    writer = csv.writer(out)
                    writer.writerow(header)
                    header_written = True
                for row in reader:
                    writer.writerow(row)

print()
print(f"Finished: {len(successful)}/{total} successful; "
      f"{len(failed)} failed.")
print(f"Combined CSV: {summary_dir / 'exp2.csv'}")
print(f"Raw results: {raw_dir}")
print(f"Logs: {log_dir}")
print(f"Manifest: {manifest_path}")

if failed:
    print("Inspect failed jobs in the manifest and corresponding logs.")
    sys.exit(1)
PY
