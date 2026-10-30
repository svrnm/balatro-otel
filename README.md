# balatro-tracing

A Balatro mod (Steamodded) that exports OpenTelemetry traces, logs/events and metrics over
OTLP/HTTP JSON, plus a [Weaver](https://github.com/open-telemetry/weaver) registry that defines
every name it emits on top of OpenTelemetry semantic conventions v1.44.0.

```
otel-trace/            the mod: main.lua (game hooks), otel.lua (OTLP exporter), otel-trace.json
test.lua               offline check of the exporter; writes sample OTLP payloads
telemetry/registry/    Weaver registry: attributes, spans, events, metrics, attribute groups
telemetry/.weaver.toml live-check matchers (how emitted telemetry maps to registry signals)
telemetry/live-check.sh        start/stop Weaver live-check plus its collector (otelcol-live-check.yaml)
telemetry/e2e.sh, autoplay.py  automated play test through BalatroBot
```

## Run

```sh
# Grafana + Tempo/Loki/Prometheus with an OTLP collector on :4318, UI on http://localhost:3000.
# telemetry/otelcol-lgtm.yaml adds two things to its collector: an event.name copy for Loki, and a
# copy of all OTLP input to compy (local collector on the Mac, 127.0.0.1:14318) which sends it to
# Bronto EU. Data lives in the balatro-lgtm-data volume.
docker network create balatro-otel
docker run -d --rm --name lgtm --network balatro-otel -p 3000:3000 -p 4317:4317 -p 4318:4318 \
  -v balatro-lgtm-data:/data -v "$PWD/telemetry/otelcol-lgtm.yaml:/otel-lgtm/otelcol-config.yaml:ro" \
  grafana/otel-lgtm:0.37.0

# Install the mod (smods ignores symlinked mod folders, so copy) and launch with Lovely
cp -R otel-trace ~/Library/Application\ Support/Balatro/Mods/
~/Library/Application\ Support/Steam/steamapps/common/Balatro/run_lovely_macos.sh
```

The mod sends to `$OTEL_EXPORTER_OTLP_ENDPOINT` (default `http://127.0.0.1:4318`) from a
background thread, every 10 s and at the end of each blind and run.

## Check

```sh
lua test.lua /tmp/otlp   # offline: asserts the OTLP shape, writes traces/logs/metrics.json

# Registry is valid (expect only "definition/2 is not yet stable" warnings)
docker run --rm -v "$PWD/telemetry:/telemetry" otel/weaver:v0.28.0 registry check --v2 -r /telemetry/registry

# Emitted telemetry matches the registry. live-check.sh starts Weaver and a collector on :4319
# that forwards to Weaver and to lgtm; send telemetry there, then stop for the summary.
telemetry/live-check.sh start
for s in traces logs metrics; do
  curl -s -H 'content-type: application/json' --data-binary @/tmp/otlp/$s.json localhost:4319/v1/$s
done
telemetry/live-check.sh stop   # report: telemetry/live-check-report/live_check.json
```

To check a manual session, launch the game with `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4319`
between `start` and `stop`.

## End-to-end test (automated play)

[BalatroBot](https://github.com/coder/balatrobot) exposes the game over JSON-RPC;
`telemetry/autoplay.py` plays one seeded run through it (skip, play, discard, shop, pack, game over).
For the first 4 rounds it uses BalatroBot's debug `set` to win on the last hand and to have money
in the shop, so those blinds carry a forced `balatro.blind.score`; after that it plays until it loses.

```sh
telemetry/install-balatrobot.sh   # once: Lovely 0.10.0, Steamodded beta-1814a, BalatroBot 1.5.2 (backs up the old ones)
telemetry/e2e.sh                  # --fast by default; pass other `balatrobot serve` flags instead, e.g.
telemetry/e2e.sh --gamespeed 1    # realistic frame/render timings
```

`e2e.sh` fails on registry violations and lists spans, events and metrics that never showed up
(some, like `app.crash`, only appear when that thing happens). Logs and the report are in
`telemetry/live-check-report/`.

## Container tests (headless, parallel, long-running)

`telemetry/container/` runs the game on Linux in Docker: native LÖVE 11.5 (Fedora's, whose shared
`liblove` Steamodded's nativefs needs), Lovely built from source for the host CPU, Xvfb, Steamodded
and BalatroBot. The game is not in the image: `Balatro.love` from the Steam install and the save
folder are mounted read-only and copied inside, so the Mac profile is never written.

```sh
docker build -t balatro-otel-runner telemetry/container
telemetry/container/run.sh                                    # smoke: one RED/WHITE run
telemetry/container/run.sh RED:WHITE:3 BLUE:RED:3 PLASMA:WHITE:3   # matrix: parallel containers
telemetry/container/run.sh RED:WHITE:30                        # soak
SERVE_ARGS=--fast telemetry/container/run.sh                   # render under Xvfb (Mesa, slow, timings not representative)
```

Each container plays `DECK:STAKE:RUNS` with seeds `C<n>0001..`; all send through the live-check
collector. After the Weaver summary, `telemetry/check_traces.py` checks content in Tempo/Loki: every
run has an outcome and blinds, each blind's score equals the sum of its hands (blinds forced by
autoplay excepted), `won` agrees with score vs target, no failed spans, no `otel hook failed` logs,
and in sessions of 8+ runs, Lua memory does not grow from run to run. A container fails if the mod
logged an export failure. Per-container output and game/BalatroBot logs:
`telemetry/live-check-report/container-<n>/`.

The image patches one BalatroBot 1.5.2 bug (a reply sent with a single non-blocking `send()` is cut
off under load). Another stays: `buy` can wait forever on its completion condition; autoplay times out
after 30 s, re-reads the state and continues.

## Dashboards

- **Grafana** (http://localhost:3000/d/balatro-otel): `telemetry/grafana/balatro.json`, provisioned
  into lgtm by mounting `telemetry/grafana` at `/otel-lgtm/balatro-dashboards` and `provider.yaml`
  into `/otel-lgtm/grafana/conf/provisioning/dashboards/` (add both `-v` flags to the lgtm `docker
  run` above). Re-read every 10 s. Sections: overview, game (hands, card actions, money, runs,
  blinds), errors & crashes (crash events, mod errors, failed spans), performance (frame time,
  update vs draw, jank by state, FPS, memory, animation queue, slow card evaluations, render).
- **Bronto**: `telemetry/bronto/dashboard.yaml`, the same sections with 25 widgets (spans, logs and
  OTLP metrics), applied with bronto-cli >= 0.9.0: `bronto dashboards validate -f
  telemetry/bronto/dashboard.yaml --live`, then `bronto dashboards apply -f ...`. On 2026-10-28
  `apply` could not run (it lists every widget in the org and `GET /widgets` returned 500), so the
  dashboard was built with `telemetry/bronto/apply_fallback.py`, which creates the same definitions
  and widgets (with apply's ownership tags) via `bronto api`. Once `GET /widgets` works, use `apply`.

## Known issues to reproduce

`telemetry/known-issues.md`: real Balatro bugs (crashes, softlocks, wrong scoring, performance) with
how to trigger them through BalatroBot and what the telemetry should show.

## Conventions

- Names are defined in `telemetry/registry`; custom names live under `balatro.*`, durations are
  seconds, counts use `{unit}` annotations.
- Events are log records with an event name linked to the open span (OTEP 4430), not span events.
- Upstream conventions used: `service.*`, `telemetry.sdk.*`, `os.type`, `session.id` +
  `session.start`, `app.jank`, `app.crash` + `exception.*`, `error.type`.
- Known findings that stay: `telemetry.sdk.language = lua` and `error.type = lua_error` are values
  outside the upstream enums (allowed, reported as improvements); Lua errors have no
  `exception.type`.
