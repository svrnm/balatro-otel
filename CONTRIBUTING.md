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
  and `SDK_VERSION` in `mod/otel-trace/otel.lua`, then push a `vX.Y.Z` tag. The release workflow
  reruns CI before publishing the ZIPs, `SHA256SUMS`, and build provenance attestations.

Container images are pinned by digest and GitHub Actions by commit; Dependabot proposes updates.
Other downloaded archives and the Rustup 1.28.2 bootstrap binaries are pinned in
`telemetry/container/downloads.sha256`. When updating one, fetch it from its official upstream,
review the release and source changes, compute its SHA-256, and update the URL and checksum together.
The checksums detect changes after the initial pin; they do not replace reviewing the dependency.
Lovely is pinned to its v0.10.0 commit, built with its Cargo lockfile and `nightly-2026-10-29`.
Update and test that toolchain pin explicitly when upgrading Lovely.

Never commit game files (`Balatro.love`, extracted Lua, sprites, audio) or recordings of the game.
