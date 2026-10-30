#!/usr/bin/env bash
# Containerized telemetry test: Weaver live-check plus one game container per spec, in parallel,
# then the live-check summary. A spec is DECK:STAKE:RUNS[:CHAOS[:SCENARIO]]; each container plays RUNS runs,
# with the fault-injection scenarios in CHAOS (comma-separated, see telemetry/chaos) if given, or
# instead runs one known-issue reproduction from telemetry/scenarios.py (e.g. RED:WHITE:1::perkeo).
#   run.sh                              smoke: RED:WHITE:1
#   run.sh RED:WHITE:3 BLUE:RED:3 ...   matrix
#   run.sh RED:WHITE:30                 soak
# SEED_PREFIX (default C, at most 3 characters) starts the seeds, so repeated calls play new runs.
# SERVE_ARGS (default "--headless --fast") go to `balatrobot serve`; use "--fast" to exercise
# rendering under Xvfb (Mesa software rendering, so timings are not representative).
# Needs: the stack (telemetry/stack, see README) and the image: docker build -t balatro-otel-runner telemetry/container
set -euo pipefail
cd "$(dirname "$0")/../.."
GAME="$HOME/Library/Application Support/Steam/steamapps/common/Balatro/Balatro.app/Contents/Resources/Balatro.love"
SAVES="$HOME/Library/Application Support/Balatro"
OUT=telemetry/live-check-report
SPECS=("${@:-RED:WHITE:1}")

docker inspect -f '{{.State.Running}}' otelcol >/dev/null 2>&1 || { echo "the stack is not running: docker compose -f telemetry/stack/compose.yaml up -d"; exit 1; }
START=$(date +%s)
telemetry/live-check.sh start

pids=()
extra=()
[ -n "${SERVE_ARGS:-}" ] && extra=(-e "SERVE_ARGS=$SERVE_ARGS")
[ -n "${RECORD:-}" ] && extra+=(-e RECORD=1) # screen recording to <out>/screen.mkv
for i in "${!SPECS[@]}"; do
  IFS=: read -r deck stake runs chaos scenario <<<"${SPECS[$i]}"
  docker rm -f "balatro-run-$i" >/dev/null 2>&1 || true
  rm -rf "$OUT/container-$i" && mkdir -p "$OUT/container-$i"
  docker run --rm --name "balatro-run-$i" --network balatro-otel \
    -v "$GAME:/game/Balatro.love:ro" -v "$SAVES:/saves:ro" -v "$PWD:/work:ro" -v "$PWD/$OUT/container-$i:/out" \
    -e OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol-live-check:4318 \
    -e DECK="$deck" -e STAKE="$stake" -e RUNS="$runs" -e SEED_PREFIX="${SEED_PREFIX:-C}$i" -e OTEL_CHAOS="${chaos:-}" -e SCENARIO="${scenario:-}" \
    ${extra[@]+"${extra[@]}"} \
    balatro-otel-runner >"$OUT/container-$i/output.log" 2>&1 &
  pids+=($!)
  echo "container $i: $deck/$stake x$runs ${chaos:+chaos=$chaos }${scenario:+scenario=$scenario }-> $OUT/container-$i/"
done

failed=0
for i in "${!pids[@]}"; do
  wait "${pids[$i]}" || { echo "container $i failed:"; tail -15 "$OUT/container-$i/output.log"; failed=1; }
done
telemetry/live-check.sh stop || failed=1
sleep 30 # let the last batches reach Jaeger and the log file (a crashed run's trace has arrived later than 10 s)
python3 telemetry/check_traces.py "$START" || failed=1
exit "$failed"
