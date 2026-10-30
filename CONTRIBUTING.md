# Contributing

Issues and pull requests are welcome.

- **New telemetry**: define the name in `telemetry/registry` first (custom names under `balatro.*`,
  OpenTelemetry semantic conventions where one exists), then emit it from the mod. CI runs Weaver's
  registry check; `telemetry/live-check.sh` checks what the mod actually sends.
- **Mod code** runs on LuaJIT inside the game: every hook goes through `safe()` so a bug in the mod
  never crashes a run, and nothing blocks the game loop (exports run on a worker thread).
- **Before a pull request**: `lua tests/otel_test.lua /tmp/otlp`, and ideally one container run
  (`telemetry/container/run.sh`) with `check_traces.py` passing. CI also runs ruff and shellcheck.
- **Releases**: bump the version in `mod/otel-trace/otel-trace.json`, `mod/otel-trace/manifest.json`
  and `SDK_VERSION` in `mod/otel-trace/otel.lua`, then push a `vX.Y.Z` tag.

Never commit game files (`Balatro.love`, extracted Lua, sprites, audio) or recordings of the game.
