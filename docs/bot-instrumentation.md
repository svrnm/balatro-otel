# Bot instrumentation

Unreleased version 0.4.0 instruments the Python test player and the optional BalatroBot Lua API
server. The 0.3.0 release remains unchanged. The generated [signal reference](bot-signals.md)
defines the custom operations and imported RPC signals.

## What appears in the backend

| Service | Scope |
| --- | --- |
| `balatro-autoplay` | Python run/scenario, decisions, hand-selection strategy, JSON-RPC client calls, recovery events and metrics |
| `balatrobot` | Lua API command dispatch through response completion, including asynchronous callbacks, errors and disconnects |
| `balatro` | Existing run/blind/hand/scoring/card traces, now linked to the command active when a span starts |

The Python `balatrobot serve` launcher's process-startup internals are not instrumented. Its API
health probes are observed by the instrumented Lua server, even without an instrumented client.
BalatroBot remains an optional dependency of the game mod.

A Python run contains decision spans and RPC client spans. Each request sends W3C `traceparent` in
an HTTP header. The Lua server span uses that remote parent; it does not start an unrelated trace.
The game retains its existing run/blind/hand hierarchy and adds span links to the active server
command. Server spans can also link to the game span active when dispatch begins.

For a `play` request, the server span includes the scoring animation and waiting for the response
condition. It does not end when dispatch returns. The resulting hand/scoring/card spans link to
that server span. Existing long-lived game spans, such as an already-open shop, retain their
creation-time links; this does not add a separate command link to every game log record.

## Running

Rebuild the test runner to install the hash-locked Python SDK dependencies:

```sh
docker build -t balatro-otel-runner telemetry/container
telemetry/container/run.sh BLUE:WHITE:1
```

The existing runner sends all three services to live-check and the local stack. It now verifies
client/server parentage and command-to-hand links after the existing game consistency checks.
Readiness calls that fail before the API starts appear as failed client spans; the player's normal
startup polling continues. Successful commands must have matching server spans.

For local Python execution, use the locked dependencies through `uv`:

```sh
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318 \
  uv run --with-requirements telemetry/container/bot-requirements.txt \
  python telemetry/autoplay.py --seed BOT0001 --deck BLUE --stake WHITE
```

Start the game/API separately using BalatroBot as before. `telemetry/e2e.sh` handles that launch for
local testing and points both Python and the game at live-check. Scenarios use the same instrumented
RPC helper and add a scenario span. Scripts using a bare Python interpreter now need the dependencies
installed into that environment; they are not silently run without instrumentation.

Python uses the standard SDK (currently pinned to 1.45.2) and the OTLP/HTTP protobuf exporters.
Standard endpoint/header/TLS and sampler environment settings are handled by those exporters and the
SDK. `OTEL_SERVICE_NAME` can override the Python service name. The Lua server uses a separate instance
of the existing JSON exporter, follows the game mod's effective endpoint, and shares its `session.id`.
The Lua server service name is fixed to `balatrobot`; its instance ID is distinct from the game's.

## Semantics and lifecycle

RPC conventions are imported from semantic-conventions v1.44.0: JSON-RPC spans have CLIENT/SERVER
kinds and method-based names, with `rpc.system.name=jsonrpc`, protocol version, request ID, and peer
address information where available. Unknown methods use `_OTHER`, span name `jsonrpc`, and the
original method on the span only. Python uses the SDK's semantic convention constants.

Weaver's v1.44.0 JSON-RPC span definitions omit `rpc.system.name` from their attribute lists although
their notes require it. A local correlation attribute group references the upstream attribute to
cover this gap, without redeclaring or suppressing validation of it. Legacy dependency span imports
use their `span.rpc.jsonrpc.call.*` IDs; live-check matchers use resolved `rpc.jsonrpc.call.*` types.

The module reads the HTTP header block already held by BalatroBot at dispatch. It does not modify
upstream source files, RPC parameters, or response bodies. Duplicate/invalid traceparent values,
zero IDs, and unsupported header layouts are ignored; requests still execute. Parsing is bounded
to the first 8 KiB of headers. Remote unsampled requests do not export Lua server spans; their metrics
still record. The independent game exporter retains its existing all-recorded behavior.

Protocol failures rejected before dispatch remain in upstream server logs; a traced client still
records the failed reply. The adapter does not add an HTTP transport span for malformed HTTP.

Responses complete requests exactly once. Disconnects, superseding commands, a 120-second server
observation deadline, server close, and game crashes abandon the observation with an error. Ending
an observation does not cancel the underlying game action. Callback ownership prevents late
responses from finishing a newer request's span; it does not change upstream socket/protocol behavior.
All game-side observations are guarded, and existing callback/command return values are preserved.

The player assigns unique request IDs and validates matching JSON-RPC replies. Transport errors,
malformed protocol replies, and JSON-RPC error objects have distinct error types. Recovery re-reads
state, since a timeout does not prove that the action failed to execute. It does not transparently
replay an uncertain `play`, `buy`, or other action.

Hand selection records `flush`, `rank_group`, or `high_cards`. Decision spans describe state and
whether debug assistance is enabled; their nested RPC spans identify the commands taken. The new
instrumentation does not record full request parameters or game-state responses. Existing upstream
messages captured by the Steamodded log bridge are unaffected.

## Metrics and export lifecycle

`rpc.client.call.duration` and `rpc.server.call.duration` are upstream histograms in seconds, with
buckets reaching 120 seconds. `balatro.bot.decisions` counts decision iterations by normalized game
state. RPC metric methods use a fixed allowlist; status codes use a fixed standard-code set plus
`_OTHER`. Error types are bounded categories. Request IDs, seeds, card data, and trace IDs stay out
of metric dimensions. The client additionally records its configured server address/port.

Python batches traces/logs, exports metrics periodically, and shuts down all three providers on
normal process exit to flush the final run and metrics. The server uses the game's existing background
HTTP export mechanism, flushing completed command observations. Hard process termination cannot
promise a final flush. Export failures do not trigger command retries.

## Validation

Tests cover remote-parent extraction, async completion timing, links without reparenting game
spans, unsampled contexts, rejection/error status, disconnects, timeouts, stale callbacks, original
return values, and observer failures. Python tests use the real SDK and its OTLP encoders, including
logs and histograms. Corrupt parent/link graphs are rejected by the integration verifier.

An actual BLUE/WHITE run produced 71 client spans, 70 server spans, 46 decision spans and 27
hand-selection spans. Sixty-nine successful client/server calls shared the expected trace and parent;
the other client calls were startup connection failures, while the server also observed the
launcher's standalone health probe. All 21 hands linked to `play` commands. Five blinds passed score
consistency checks, and Weaver reported zero violations.

A second run, seed `BOT0001`, completed through ante 2, round 5 and exported all three services to
local compy on port 14318. Its receiver counters increased with no new refusals; the game and Python
exporter logs reported no export failures. The shared game/server session was
`80b58921-1dbb-45a5-bd36-2ad422cbba2b`; the seed attribute also identifies the Python run.

`check_bot_traces.py` assumes the default all-sampled, closed-world test run and default service names.
It is not a general production trace completeness checker. Actual gameplay compatibility was tested
with the runner's pinned BalatroBot 1.5.2; its exported globals and callback structure are the adapter's
compatibility boundary. Tracestate and baggage are not forwarded by the Lua adapter.

Weaver skill verification:

- [x] Versioned manifest uses `definition_manifest/2.0` and schema URL ending in `0.4.0`.
- [x] Local definitions and enum members declare stability.
- [x] Custom signals use `balatro.*`; RPC spans/metrics and standard attributes are imported/referenced.
- [x] No boundary-domain definitions are duplicated locally.
- [x] Counters have no `_total` suffix; duration histograms use seconds.
- [x] Templates use v2 helpers; the resolved upstream schema was inspected before authoring imports.
- [~] Generated artifacts are Markdown, not language code; their whitespace/drift is checked. Python
  sources use the pinned Ruff formatter.
- [x] CI runs registry check, tests, emitted-payload live-check, generation/drift checks and baseline diff.
- [x] Changed files were re-read and remaining compatibility/sampling/flush limits are documented.

Guidance: [OTel Python skill](https://github.com/ollygarden/opentelemetry-agent-skills/tree/main/skills/otel-python),
[semantic conventions skill](https://github.com/ollygarden/opentelemetry-agent-skills/tree/main/skills/otel-semantic-conventions),
and [Weaver skill](https://github.com/ollygarden/opentelemetry-agent-skills/tree/main/skills/otel-weaver).
The [released RPC model](https://github.com/open-telemetry/semantic-conventions/tree/v1.44.0/model/rpc)
is the naming/attribute source; the custom bot decisions and recovery semantics are project choices.
