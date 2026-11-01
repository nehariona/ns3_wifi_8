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
