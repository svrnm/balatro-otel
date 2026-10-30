#!/usr/bin/env bash
# Validate telemetry against the registry with Weaver live-check.
#   live-check.sh start   Weaver + a collector that accepts OTLP/HTTP on localhost:4319 and forwards
#                         to Weaver and to the stack's collector (both on the balatro-otel network)
#   live-check.sh stop    drains the collector, writes the report and prints a summary; exits 1 on
#                         registry violations
# Report and logs: telemetry/live-check-report/
set -euo pipefail
cd "$(dirname "$0")"
OUT=live-check-report

start() {
  docker rm -f weaver-live otelcol-live-check >/dev/null 2>&1 || true
  mkdir -p "$OUT" && rm -f "$OUT/live_check.json"
  docker run -d --name weaver-live --network balatro-otel -p 4320:4320 \
    -v "$PWD:/telemetry:ro" -v "$PWD/$OUT:/out" otel/weaver:v0.28.0 \
    registry live-check --v2 -r /telemetry/registry --config /telemetry/.weaver.toml \
    --otlp-grpc-address 0.0.0.0 --otlp-grpc-port 4317 --admin-port 4320 \
    --inactivity-timeout 3600 --format json --output /out >/dev/null
  curl -s --retry 60 --retry-all-errors --retry-delay 1 localhost:4320/health >/dev/null
  docker run -d --name otelcol-live-check --network balatro-otel -p 4319:4318 \
    -v "$PWD/otelcol-live-check.yaml:/etc/otelcol-contrib/config.yaml:ro" \
    otel/opentelemetry-collector-contrib:0.162.0 >/dev/null
  curl -s --retry 30 --retry-all-errors --retry-delay 1 -o /dev/null -X POST \
    -H 'content-type: application/json' -d '{}' localhost:4319/v1/logs
  echo "live-check ready: send OTLP/HTTP to http://localhost:4319"
}

stop() {
  docker stop -t 30 otelcol-live-check >/dev/null # graceful: flushes its export queues first
  docker logs otelcol-live-check >"$OUT/otelcol.log" 2>&1; docker rm otelcol-live-check >/dev/null
  curl -s -X POST localhost:4320/stop >/dev/null
  docker wait weaver-live >/dev/null || true
  docker logs weaver-live >"$OUT/weaver.log" 2>&1; docker rm weaver-live >/dev/null
  python3 - "$OUT/live_check.json" <<'EOF'
import collections, json, sys
report = json.load(open(sys.argv[1]))
s = report["statistics"]
violations = collections.Counter()
def walk(o):
    if isinstance(o, dict):
        if o.get("type") == "PolicyFinding" and o.get("level") == "violation":
            violations[f"{o['signal_type']} {o.get('signal_name') or ''}: {o['message']}"] += 1
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(report["samples"])
spans = {m["id"].removeprefix("match.span."): m["matched"] for m in s["matchers"] if m["id"].startswith("match.span.")}
print(f"samples: {len(report['samples'])}, entities: {s['total_entities_by_type']}, findings: {s['advice_level_counts']}")
print("spans matched:", spans)
for kind, seen in [("span", spans), ("event", s["seen_registry_events"]), ("metric", s["seen_registry_metrics"])]:
    for name, n in seen.items():
        if not n: print(f"not seen: {kind} {name}")
for k, v in violations.items(): print(f"VIOLATION x{v}: {k}")
sys.exit(1 if violations else 0)
EOF
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  *) echo "usage: $0 start|stop"; exit 2 ;;
esac
