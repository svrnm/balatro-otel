# OTel Trace

OpenTelemetry for Balatro. Every run, blind, hand (down to each card and joker that scored), shop
visit and booster pack becomes a span; discards, purchases, scoring effects, frame hitches and crashes
become log events; frame timing, memory, score and money become metrics. Everything is sent over
OTLP/HTTP (JSON) to an OpenTelemetry Collector or any backend that accepts OTLP.

Unofficial fan project, not affiliated with or endorsed by LocalThunk or Playstack.

## Install

1. Install [Lovely](https://github.com/ethangreen-dev/lovely-injector) and
   [Steamodded](https://github.com/Steamodded/smods) (see their install guides for your OS).
2. Put this `otel-trace` folder into your Balatro `Mods` folder, or install
   [OTel Trace from Thunderstore](https://thunderstore.io/c/balatro/p/svrnm/otel_trace/) with a mod manager (r2modman, Gale, imm).
3. Run something that receives OTLP on `localhost:4318`, for example the Collector + Jaeger +
   Prometheus stack from the [repository](https://github.com/svrnm/balatro-otel).

## Configure

In the game: **Mods → OTel Trace → Config** shows where telemetry goes. Copy a URL (for example
`http://192.168.1.10:4318`) and click **Paste from clipboard**; **Reset to default** goes back to
`http://127.0.0.1:4318`. Balatro's text fields can't type URLs, hence the clipboard. The setting is
saved in the game's `config` folder and survives mod updates.

The environment variable takes precedence over the in-game setting:

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://127.0.0.1:4318` | Where to send; `/v1/traces`, `/v1/logs` and `/v1/metrics` are appended |

## Privacy

The mod sends only to the endpoint above, which is your own machine unless you change it. It sends
game data (seed, deck, cards, scores, timings), the OS type, your GPU/renderer name, display size and
game settings, a random session id per game start, and for crashes and mod errors the Lua error
message and stack trace (they name game and mod files). It reads no account or Steam data. If nothing
listens on the endpoint, the data is dropped. Disable the mod in Steamodded's Mods menu to stop it.

## License

Apache-2.0
