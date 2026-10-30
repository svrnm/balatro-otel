#!/usr/bin/env bash
# End-to-end telemetry test: installs the mod, starts Weaver live-check, launches Balatro through
# BalatroBot, plays one seeded run (autoplay.py), closes the game, then fails on registry
# violations and lists spans, events and metrics from the registry that never showed up.
# Needs: the stack (telemetry/stack, see README), BalatroBot + Steamodded/Lovely installed, uv.
# Extra args go to `balatrobot serve`; e.g. drop the default --fast for realistic frame timings.
set -euo pipefail
cd "$(dirname "$0")/.."
SEED=${SEED:-OTELTEST}
SERVE_ARGS=("${@:---fast}")
LOG=telemetry/live-check-report/balatrobot.log

docker inspect -f '{{.State.Running}}' otelcol >/dev/null 2>&1 || { echo "the stack is not running: docker compose -f telemetry/stack/compose.yaml up -d"; exit 1; }
cp mod/otel-trace/*.lua mod/otel-trace/otel-trace.json "$HOME/Library/Application Support/Balatro/Mods/otel-trace/"
telemetry/live-check.sh start

OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4319 uvx balatrobot serve --logs-path telemetry/live-check-report/balatrobot-logs "${SERVE_ARGS[@]}" </dev/null >"$LOG" 2>&1 &
SERVE_PID=$!

# `balatrobot serve` only closes the game on Ctrl+C, which a background job in a script ignores
# (and giving it its own process group with `set -m` hangs the game on startup). So do what its
# shutdown does: terminate the game it started (PID from its log), then stop uvx and its child.
stop_game() {
  local game
  game=$(sed -n 's/.*Balatro started (PID: \([0-9]*\)).*/\1/p' "$LOG")
  [ -n "$game" ] && kill "$game" 2>/dev/null
  pkill -P "$SERVE_PID" 2>/dev/null || true
  kill "$SERVE_PID" 2>/dev/null || true
  for _ in $(seq 10); do [ -n "$game" ] && kill -0 "$game" 2>/dev/null || return 0; sleep 1; done
  kill -KILL "$game" 2>/dev/null || true
}
trap 'stop_game; telemetry/live-check.sh stop >/dev/null 2>&1 || true' EXIT

python3 telemetry/autoplay.py --seed "$SEED"
sleep 12 # past one metric export interval, so the last spans, logs and metrics leave the game
stop_game
trap - EXIT
telemetry/live-check.sh stop
