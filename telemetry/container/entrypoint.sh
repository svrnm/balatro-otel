#!/usr/bin/env bash
# Runs inside the container. Mounts (read-only): /game/Balatro.love (Steam package), /saves (the
# Balatro save folder, copied so the host profile is never written), /work (this repository).
# Writable: /out gets the game (Lovely) and BalatroBot logs on exit.
# Plays $RUNS runs with seeds ${SEED_PREFIX}0001.. (deck $DECK, stake $STAKE), sending telemetry
# to $OTEL_EXPORTER_OTLP_ENDPOINT. $SERVE_ARGS go to `balatrobot serve` (default: --headless --fast).
# $OTEL_CHAOS (optional) installs the fault-injection mod with those scenarios (telemetry/chaos).
# $RECORD (optional) records the virtual screen to /out/screen.mkv (needs SERVE_ARGS without --headless).
set -euo pipefail
RUNS=${RUNS:-1} SEED_PREFIX=${SEED_PREFIX:-OTEL} DECK=${DECK:-RED} STAKE=${STAKE:-WHITE}
OTEL_CHAOS=${OTEL_CHAOS:-}
trap 'cp -R /mods/lovely/log /out/lovely-log 2>/dev/null; cp -R /tmp/balatrobot-logs /tmp/balatrobot.log /out/ 2>/dev/null || true' EXIT
has_chaos() { [[ ",$OTEL_CHAOS," == *",$1,"* ]]; }

mkdir -p /balatro && unzip -q -o /game/Balatro.love -d /balatro
SAVE="$HOME/.local/share/love/balatro"
mkdir -p "$SAVE" && cp -R /saves/settings.jkr /saves/1 "$SAVE/"
cp -R /work/otel-trace /mods/otel-trace
if [ -n "$OTEL_CHAOS" ]; then
  cp -R /work/telemetry/chaos/otel-chaos /mods/otel-chaos
  export OTEL_CHAOS
  # drawing is skipped in headless mode; "render" alone just switches mode (a baseline for draw_heavy)
  { has_chaos draw_heavy || has_chaos render; } && SERVE_ARGS=${SERVE_ARGS:---fast}
fi

Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
export DISPLAY=:99
if [ -n "${RECORD:-}" ]; then
  sleep 1 # Xvfb up
  ffmpeg -loglevel error -f x11grab -framerate 15 -video_size 1920x1080 -i :99 -c:v mjpeg -q:v 4 /out/screen.mkv </dev/null &
  recorder=$!
fi

# shellcheck disable=SC2086 # SERVE_ARGS is a flag list
balatrobot serve --platform native --balatro-path /balatro --love-path "$(command -v love)" \
  --lovely-path /usr/local/lib/liblovely.so --logs-path /tmp/balatrobot-logs \
  ${SERVE_ARGS:---headless --fast} >/tmp/balatrobot.log 2>&1 &

status=0
if [ -n "${SCENARIO:-}" ]; then
  # a known-issue reproduction (telemetry/scenarios.py); its RESULT lines are the outcome, and a
  # crash or softlock is what it is looking for, so it does not fail the container
  echo "=== scenario $SCENARIO"
  python3 /work/telemetry/scenarios.py "$SCENARIO" || true
  RUNS=0
fi
for i in $(seq "$RUNS"); do
  seed=$(printf "%s%04d" "$SEED_PREFIX" "$i")
  echo "=== run $i/$RUNS seed $seed deck $DECK stake $STAKE"
  if ! python3 /work/telemetry/autoplay.py --seed "$seed" --deck "$DECK" --stake "$STAKE"; then
    # after an injected crash the game sits on its crash screen and the bot cannot continue
    has_chaos crash && { echo "bot stopped after the injected crash (expected)"; break; }
    status=1; break
  fi
done
[ -n "${recorder:-}" ] && { kill -INT "$recorder"; wait "$recorder" || true; }
sleep 12 # past one metric export interval, so the last spans, logs and metrics leave the game
if grep -h "\[otel\]" /mods/lovely/log/*.log | grep -i "fail\|died"; then
  echo "otel-trace reported failures (above)"; status=1
fi
exit "$status"
