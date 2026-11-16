# Contributing

Issues and pull requests are welcome.

- **New telemetry**: define the name in `telemetry/registry` first (custom names under `balatro.*`,
  OpenTelemetry semantic conventions where one exists), then emit it from the mod. CI runs Weaver's
  registry check; `telemetry/live-check.sh` checks what the mod actually sends.
- **Mod code** runs on LuaJIT inside the game: every hook goes through `safe()` so a bug in the mod
  never crashes a run, and nothing blocks the game loop (exports run on a worker thread).
- **Before a pull request**: `lua tests/otel_test.lua /tmp/otlp`, and ideally one container run
  (`telemetry/container/run.sh`) with `check_traces.py` passing. CI also runs ruff and shellcheck.
  Run `lua tests/scoring_test.lua /tmp/otlp` for scoring-hook behavior and emitted signal samples.
  CI validates those samples with Weaver live-check. After registry changes, regenerate
  `docs/scoring-signals.md` using the command in the README; CI checks it for drift and prints the
  registry diff against the base commit.
  For bot changes, also run `lua tests/bot_test.lua /tmp/otlp` and
  `BOT_TEST_OUTPUT=/tmp/otlp uv run --with-requirements telemetry/container/bot-requirements.txt python tests/bot_telemetry_test.py`.
  Regenerate `docs/bot-signals.md` using the same Weaver command with target `bot`.
  The container runner checks client/server parentage and links from commands to hands.
- **Releases**: bump the version in `mod/otel-trace/otel-trace.json`, `mod/otel-trace/manifest.json`
  and `SDK_VERSION` in `mod/otel-trace/otel.lua`, plus the Python bot's version/schema constants and
  the registry schema URL when applicable, then push a `vX.Y.Z` tag. The release workflow
  reruns CI before publishing the ZIPs, `SHA256SUMS`, and build provenance attestations.

Container images are pinned by digest and GitHub Actions by commit; Dependabot proposes updates.
Other downloaded archives and the Rustup 1.28.2 bootstrap binaries are pinned in
`telemetry/container/downloads.sha256`. When updating one, fetch it from its official upstream,
review the release and source changes, compute its SHA-256, and update the URL and checksum together.
The checksums detect changes after the initial pin; they do not replace reviewing the dependency.
Lovely is pinned to its v0.10.0 commit, built with its Cargo lockfile and `nightly-2026-10-29`.
Update and test that toolchain pin explicitly when upgrading Lovely.

The Python bot uses hash-locked dependencies in `telemetry/container/bot-requirements.txt`.
To update them, review the SDK/exporter releases, edit `bot-requirements.in`, then run
`uv pip compile --generate-hashes --universal telemetry/container/bot-requirements.in -o telemetry/container/bot-requirements.txt`
and rebuild/test the runner. JSON-RPC conventions remain pinned to the manifest's released semconv
version, even when the SDK bundles newer constants.

Never commit game files (`Balatro.love`, extracted Lua, sprites, audio) or recordings of the game.
