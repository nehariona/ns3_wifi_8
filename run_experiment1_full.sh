#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# EXPERIMENT 1 - P-EDCA adoption sweep (complete, self-contained)
#
#   Swept variable : % of the VO STAs that use P-EDCA = 0, 25, 50, 75, 100
#                    (= 0, 5, 10, 15, 20 of the 20 VO STAs)
#   Traffic types  : cbr, poisson, poissonBurst
#   Fixed          : 32 STAs (VO:VI:BE:BK = 20:4:4:4), 12 Mbit/s per AC (fixed per-AC load)
#   Replicates     : 5 RngSeed values x 2 RngRun values = 10 per configuration
#   Simulation     : 300 s measured, 5 s warm-up, 5 s drain
#   Parallelism    : 6 jobs (dynamic pool, works with the bash/xargs that ship with macOS)
#   Total runs     : 3 traffic x 5 adoption x 5 seeds x 2 runs = 150
#
# Only command-line options that your existing sweep script already uses are passed to the
# simulator (so it works with the same scratch binary).  Paired design: for a given seed/run
# every adoption level sees the same random traffic.
#
# Run from the ns-3 root directory:
#   ./run_exp1_complete.sh                 # the full experiment
#   ./run_exp1_complete.sh --smoke         # 1 seed x 1 run, 10 s: pipeline test
#   ./run_exp1_complete.sh --dry-run       # print the plan, run nothing
#   ./run_exp1_complete.sh --help
#
# Output layout (everything under results/exp1/):
#   config/                     run_settings.txt, exp1_scenarios.csv
#   <traffic>/raw/              one CSV per run   (L12_D1_exp1_<pct>pct_run<replicate>.csv)
#   <traffic>/logs/             one console log per run
#   <traffic>/analysis/         summary_mean_ci.csv, paired_*.csv, plots, goals_check.txt
#   summary/                    the three traffic types combined
#   console.log, failed_runs.txt, README.txt
# ==============================================================================

# ---- Paths ---------------------------------------------------------------------
PROGRAM="${PROGRAM:-scratch/pedca-txop-ratio-sweep}"   # same target as your sweep script
OUT="${OUT:-fixing/exp1}"

# ---- Experiment 1 settings (from the experiment list) -----------------------------
TRAFFIC_LIST="${TRAFFIC_LIST:-cbr poisson poissonBurst}"
ADOPTION_LIST="${ADOPTION_LIST:-0 25 50 75 100}"      # % of VO STAs using P-EDCA
N_VO=20; N_VI=4; N_BE=4; N_BK=4                       # 32 STAs, ratio 20:4:4:4
LOAD_PER_AC="${LOAD_PER_AC:-12}"                      # Mbit/s per AC (fixed per-AC policy)
SEEDS="${SEEDS:-1}"                           # RngSeed values
RUNS="${RUNS:-1}"                                     # RngRun values per seed (1..RUNS)
SIM_TIME="${SIM_TIME:-120}"
WARMUP_TIME="${WARMUP_TIME:-5}"
DRAIN_TIME="${DRAIN_TIME:-5}"
JOBS="${JOBS:-8}"

# ---- Traffic shape (as in your sweep script) -----------------------------------
BURST_ON_TIME="${BURST_ON_TIME:-1.0}"
BURST_OFF_MEAN="${BURST_OFF_MEAN:-2.0}"
PRESERVE_MEAN_LOAD="${PRESERVE_MEAN_LOAD:-1}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-1024}"
BSS_RADIUS="${BSS_RADIUS:-5}"

# ---- P-EDCA parameters (same values as your sweep script) ----------------------
PEDCA_QSRC_THR="${PEDCA_QSRC_THR:-3}"
PEDCA_PSRC_THR="${PEDCA_PSRC_THR:-4}"
PEDCA_DS_AIFSN="${PEDCA_DS_AIFSN:-2}"
PEDCA_CW_DS="${PEDCA_CW_DS:-0}"
PEDCA_STAGE2_AIFSN="${PEDCA_STAGE2_AIFSN:-2}"
PEDCA_STAGE2_CWMIN="${PEDCA_STAGE2_CWMIN:-3}"
PEDCA_STAGE2_CWMAX="${PEDCA_STAGE2_CWMAX:-7}"
PEDCA_STAGE2_WINDOW_US="${PEDCA_STAGE2_WINDOW_US:-0}"
AP_PEDCA="${AP_PEDCA:-1}"
SAME_CONTENT_MAX_DELAY_NS="${SAME_CONTENT_MAX_DELAY_NS:-800}"

# ---- Optional extras (OFF by default: only for simulator builds that know them) ----
AMPDU_ARG="${AMPDU_ARG:-0}"      # 1 = also pass --disableAmpdu=1
EXTRA="${EXTRA:-}"               # any extra "--option=value" flags for the simulator
AMPDU_TAG="D1"                   # file-name tag read by the analysis scripts (A-MPDU disabled)

FORCE=0; DRY=0; ANALYSE=1; SMOKE=0

usage() { sed -n '3,33p' "$0"; cat <<'U'

Options:
  --jobs N            parallel runs (default 6)
  --sim-time S        measured seconds per run (default 300)
  --seeds "1 2 3"     RngSeed values (default "1 2 3 4 5")
  --runs N            RngRun values per seed (default 2)
  --traffic "a b"     subset of: cbr poisson poissonBurst
  --adoption "0 50"   subset of adoption percentages
  --load MBPS         load per AC (default 12)
  --qsrc N --psrc N   P-EDCA thresholds (default 3 / 4)
  --program NAME      ns-3 scratch target (default scratch/pedca-txop-ratio-sweep)
  --out DIR           output folder (default results/exp1)
  --disable-ampdu-arg also pass --disableAmpdu=1 to the simulator (if it supports it)
  --extra "..."       extra simulator flags
  --force             redo runs that already have a complete result file
  --dry-run           show the plan only
  --no-analysis       skip the analysis step
  --smoke             quick test: 1 seed x 1 run, 10 s, 5 s warm-up/drain, out=results/exp1_smoke
U
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs) JOBS="$2"; shift 2 ;;
    --sim-time) SIM_TIME="$2"; shift 2 ;;
    --seeds) SEEDS="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --traffic) TRAFFIC_LIST="$2"; shift 2 ;;
    --adoption) ADOPTION_LIST="$2"; shift 2 ;;
    --load) LOAD_PER_AC="$2"; shift 2 ;;
    --qsrc) PEDCA_QSRC_THR="$2"; shift 2 ;;
    --psrc) PEDCA_PSRC_THR="$2"; shift 2 ;;
    --program) PROGRAM="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --disable-ampdu-arg) AMPDU_ARG=1; shift ;;
    --extra) EXTRA="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --no-analysis) ANALYSE=0; shift ;;
    --smoke) SMOKE=1; SEEDS="1"; RUNS=1; SIM_TIME=10; WARMUP_TIME=2; DRAIN_TIME=2; OUT="results/exp1_smoke"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# ---- Validation ----------------------------------------------------------------
[[ -x ./ns3 ]] || { echo "ERROR: run from the ns-3 root directory (./ns3 not found)." >&2; exit 1; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --jobs must be a positive integer." >&2; exit 1; }
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --runs must be a positive integer." >&2; exit 1; }
for t in $TRAFFIC_LIST; do
  case "$t" in cbr|poisson|poissonBurst) ;; *) echo "ERROR: unknown traffic '$t'." >&2; exit 1 ;; esac
done
for s in $SEEDS; do [[ "$s" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: bad seed '$s'." >&2; exit 1; }; done
for a in $ADOPTION_LIST; do
  [[ "$a" =~ ^[0-9]+$ && "$a" -le 100 ]] || { echo "ERROR: bad adoption '$a'." >&2; exit 1; }
  (( (N_VO * a) % 100 == 0 )) || { echo "ERROR: ${a}% of $N_VO VO STAs is not a whole number." >&2; exit 1; }
done
[[ "$PEDCA_PSRC_THR" -ge 1 && "$PEDCA_PSRC_THR" -le 4 ]] || { echo "ERROR: PSRC threshold must be 1-4." >&2; exit 1; }

NT=$(echo $TRAFFIC_LIST | wc -w | tr -d ' '); NA=$(echo $ADOPTION_LIST | wc -w | tr -d ' ')
NS=$(echo $SEEDS | wc -w | tr -d ' '); REPS=$(( NS * RUNS )); TOTAL=$(( NT * NA * REPS ))

echo "=============================================================="
echo "Experiment 1 - P-EDCA adoption sweep"
echo "Program:        $PROGRAM"
echo "Traffic:        $TRAFFIC_LIST"
echo "Adoption (%):   $ADOPTION_LIST   (VO:VI:BE:BK = $N_VO:$N_VI:$N_BE:$N_BK = $((N_VO+N_VI+N_BE+N_BK)) STAs)"
echo "Load per AC:    $LOAD_PER_AC Mbit/s"
echo "Replicates:     seeds [$SEEDS] x $RUNS run(s) = $REPS per configuration"
echo "Simulation:     $SIM_TIME s (+${WARMUP_TIME}s warm-up, ${DRAIN_TIME}s drain)   Jobs: $JOBS"
echo "P-EDCA:         QSRC $PEDCA_QSRC_THR, PSRC $PEDCA_PSRC_THR, DS AIFSN/CW_DS $PEDCA_DS_AIFSN/$PEDCA_CW_DS," \
     "Stage-2 AIFSN $PEDCA_STAGE2_AIFSN CW $PEDCA_STAGE2_CWMIN-$PEDCA_STAGE2_CWMAX, AP $AP_PEDCA"
echo "Total runs:     $TOTAL      Output: $OUT"
echo "=============================================================="

# ---- Folder structure ----------------------------------------------------------
mkdir -p "$OUT/config" "$OUT/summary"
for t in $TRAFFIC_LIST; do mkdir -p "$OUT/$t/raw" "$OUT/$t/logs" "$OUT/$t/analysis"; done

SCEN="$OUT/config/exp1_scenarios.csv"
echo "scenarioLabel,adoptionPct,nVoLegacy,nVoPedca,nVi,nBe,nBk" > "$SCEN"
for a in $ADOPTION_LIST; do
  nP=$(( N_VO * a / 100 )); nL=$(( N_VO - nP ))
  echo "exp1_${a}pct,${a},${nL},${nP},${N_VI},${N_BE},${N_BK}" >> "$SCEN"
done
{
  echo "Experiment 1 settings"; echo "date: $(date)"
  echo "ns-3 root: $(pwd)"; echo "program: $PROGRAM"
  command -v git >/dev/null 2>&1 && echo "git commit: $(git rev-parse --short HEAD 2>/dev/null || echo n/a)"
  echo "traffic: $TRAFFIC_LIST"; echo "adoption: $ADOPTION_LIST"; echo "load per AC (Mbit/s): $LOAD_PER_AC"
  echo "seeds: $SEEDS  runs per seed: $RUNS  (replicate id = (seedIndex-1)*$RUNS + run)"
  echo "sim/warmup/drain: $SIM_TIME/$WARMUP_TIME/$DRAIN_TIME  payload: $PAYLOAD_SIZE  radius: $BSS_RADIUS"
  echo "burst on/off mean/preserve: $BURST_ON_TIME/$BURST_OFF_MEAN/$PRESERVE_MEAN_LOAD"
  echo "QSRC/PSRC: $PEDCA_QSRC_THR/$PEDCA_PSRC_THR  DS AIFSN/CW: $PEDCA_DS_AIFSN/$PEDCA_CW_DS"
  echo "Stage2 AIFSN/CWmin/CWmax/window: $PEDCA_STAGE2_AIFSN/$PEDCA_STAGE2_CWMIN/$PEDCA_STAGE2_CWMAX/$PEDCA_STAGE2_WINDOW_US"
  echo "AP P-EDCA: $AP_PEDCA  same-content delay ns: $SAME_CONTENT_MAX_DELAY_NS  disableAmpdu arg: $AMPDU_ARG  extra: $EXTRA"
} > "$OUT/config/run_settings.txt"

# ---- Build the job list ---------------------------------------------------------
JOBFILE="$(mktemp)"; trap 'rm -f "$JOBFILE"' EXIT
LOADTAG="${LOAD_PER_AC}"
todo=0
for traffic in $TRAFFIC_LIST; do
  for a in $ADOPTION_LIST; do
    nP=$(( N_VO * a / 100 )); nL=$(( N_VO - nP ))
    rep=0
    for seed in $SEEDS; do
      for run in $(seq 1 "$RUNS"); do
        rep=$(( rep + 1 ))
        tag="L${LOADTAG}_${AMPDU_TAG}_exp1_${a}pct_run${rep}"
        file="$OUT/$traffic/raw/$tag.csv"
        if [[ "$FORCE" != 1 && -s "$file" && "$(wc -l < "$file" | tr -d ' ')" -ge 6 ]]; then continue; fi
        args="--nBe=$N_BE --nBk=$N_BK --nVi=$N_VI --nVoLegacy=$nL --nVoPedca=$nP"
        args+=" --perStationLoadFixed=0 --perAcLoadMbps=$LOAD_PER_AC --trafficModel=$traffic"
        args+=" --burstOnTime=$BURST_ON_TIME --burstOffMean=$BURST_OFF_MEAN --preserveMeanLoad=$PRESERVE_MEAN_LOAD"
        args+=" --payloadSize=$PAYLOAD_SIZE --simulationTime=$SIM_TIME --warmupTime=$WARMUP_TIME"
        args+=" --drainTime=$DRAIN_TIME --bssRadius=$BSS_RADIUS"
        args+=" --pedcaQsrcThreshold=$PEDCA_QSRC_THR --pedcaPsrcThreshold=$PEDCA_PSRC_THR"
        args+=" --pedcaDsAifsn=$PEDCA_DS_AIFSN --pedcaCwDs=$PEDCA_CW_DS --pedcaStage2Aifsn=$PEDCA_STAGE2_AIFSN"
        args+=" --pedcaStage2CwMin=$PEDCA_STAGE2_CWMIN --pedcaStage2CwMax=$PEDCA_STAGE2_CWMAX"
        args+=" --pedcaStage2WindowUs=$PEDCA_STAGE2_WINDOW_US --apPedcaSupported=$AP_PEDCA"
        args+=" --sameContentMaxDelayNs=$SAME_CONTENT_MAX_DELAY_NS --rngSeed=$seed --rngRun=$run --enablePcap=0"
        [[ "$AMPDU_ARG" == 1 ]] && args+=" --disableAmpdu=1"
        [[ -n "$EXTRA" ]] && args+=" $EXTRA"
        args+=" --scenarioLabel=exp1_${a}pct --outputCsv=$file"
        printf '%s\t%s\n' "$traffic/$tag" "$args" >> "$JOBFILE"
        todo=$(( todo + 1 ))
      done
    done
  done
done
echo "Runs to execute: $todo of $TOTAL (complete result files are skipped; use --force to redo)"
if [[ "$DRY" == 1 ]]; then echo "--dry-run: first job is:"; head -n 1 "$JOBFILE" | tr '\t' '\n'; exit 0; fi

# ---- Run ------------------------------------------------------------------------
FAILED="$OUT/failed_runs.txt"; : > "$FAILED"
if [[ "$todo" -gt 0 ]]; then
  echo "Building $PROGRAM ..."
  ./ns3 build > "$OUT/config/build.log" 2>&1 || { echo "ERROR: build failed, see $OUT/config/build.log" >&2; exit 1; }

  JOBSCRIPT="$OUT/config/.run_one_job.sh"
  cat > "$JOBSCRIPT" <<'JOB'
#!/usr/bin/env bash
# $1 = "<traffic>/<tag>"   $2 = simulator arguments
id="$1"; args="$2"; traffic="${id%%/*}"; tag="${id#*/}"
rm -f "$OUT/$traffic/raw/$tag.csv"          # the simulator APPENDS to its CSV: start clean
if ./ns3 run --no-build "$PROGRAM $args" > "$OUT/$traffic/logs/$tag.log" 2>&1 < /dev/null; then
  n=$(ls "$OUT"/*/raw/*.csv 2>/dev/null | wc -l | tr -d ' ')
  echo "[$(date +%H:%M:%S)] done: $id   (result files so far: $n)"
else
  echo "[$(date +%H:%M:%S)] FAILED: $id  (see $OUT/$traffic/logs/$tag.log)" | tee -a "$FAILED" >&2
  rm -f "$OUT/$traffic/raw/$tag.csv"
fi
JOB
  export PROGRAM OUT FAILED
  # NUL-separated  id \0 args \0  ->  xargs keeps exactly $JOBS runs busy
  tr '\t\n' '\0\0' < "$JOBFILE" | xargs -0 -n 2 -P "$JOBS" bash "$JOBSCRIPT"
fi

if [[ -s "$FAILED" ]]; then
  echo "Some runs FAILED (listed in $FAILED). Re-run this command to retry only those." >&2
  echo "If every run fails with 'Invalid command-line arguments', your simulator does not know one of the options; see the first log file." >&2
fi

# ---- Analysis -------------------------------------------------------------------
if [[ "$ANALYSE" == 1 ]]; then
  if [[ -f analyse_pedca.py ]]; then
    for t in $TRAFFIC_LIST; do
      if ls "$OUT/$t/raw/"*.csv >/dev/null 2>&1; then
        echo; echo "Analysing $t ..."
        python3 analyse_pedca.py "$OUT/$t/raw" --out "$OUT/$t/analysis" || echo "  (analysis of $t failed)"
        [[ -f goals_check.py ]] && python3 goals_check.py "$OUT/$t/raw" > "$OUT/$t/analysis/goals_check.txt" 2>&1 || true
      fi
    done
    python3 - "$OUT" <<'PY'
import glob, os, sys
import pandas as pd
base = sys.argv[1]
for kind in ("summary_mean_ci", "paired_vs_baseline", "paired_pedca_vs_legacy"):
    frames = []
    for f in sorted(glob.glob(os.path.join(base, "*", "analysis", kind + ".csv"))):
        d = pd.read_csv(f); d.insert(0, "traffic", f.split(os.sep)[-3]); frames.append(d)
    if frames:
        out = os.path.join(base, "summary", f"exp1_{kind}_all_traffic.csv")
        pd.concat(frames, ignore_index=True).to_csv(out, index=False); print("Wrote", out)
PY
  else
    echo "analyse_pedca.py not found in $(pwd): skipping analysis (raw CSVs are in $OUT/<traffic>/raw)."
  fi
fi

cat > "$OUT/README.txt" <<R
Experiment 1 - P-EDCA adoption sweep
  config/    run settings, scenario table, build log
  <traffic>/raw/       one CSV per run: L<load>_D1_exp1_<adoption>pct_run<replicate>.csv
                       replicate = (seed index - 1) * runs-per-seed + run   (same replicate = same random traffic
                       at every adoption level, so comparisons are paired)
  <traffic>/logs/      console output of every run
  <traffic>/analysis/  summary_mean_ci.csv, paired_vs_baseline.csv, paired_pedca_vs_legacy.csv, plots, goals_check.txt
  summary/             the three traffic types combined
  failed_runs.txt      empty if every run succeeded
R
echo
echo "Experiment 1 finished: $OUT"
[[ -s "$FAILED" ]] && exit 1
exit 0
