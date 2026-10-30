#!/usr/bin/env bash
# Fault-injection run: a clean baseline, a render-mode baseline and one container per fault group,
# then report.py shows where each fault surfaced next to the baseline.
# Two containers at a time: with more, an 8-vCPU Docker VM is so contended that the baseline itself
# janks for seconds and requests time out, hiding the injected faults.
# container/run.sh failing is expected: its checks are supposed to catch the faults.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=telemetry/live-check-report
START=$(date +%s)
rm -rf "$OUT"/wave-* "$OUT"/container-*

wave() {
  local n=$1; shift
  echo "== wave $n: $*"
  telemetry/container/run.sh "$@"
  echo "== wave $n exit $? (non-zero expected when a fault is caught)"
  mkdir -p "$OUT/wave-$n" && mv "$OUT"/container-* "$OUT/wave-$n/"
}

wave 1 RED:WHITE:2 RED:WHITE:2:jank,slow_joker,queue_flood,mod_error
wave 2 RED:WHITE:2:score_bug RED:WHITE:4:leak
wave 3 RED:WHITE:1:crash RED:WHITE:1:render
wave 4 RED:WHITE:1:draw_heavy
python3 telemetry/chaos/report.py "$START"
