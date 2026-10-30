# Filed as coder/balatrobot#243 (2026-10-30)

**Title:** fix(lua.core): responses are cut off when they do not fit the socket send buffer

## Description

`send_raw` in `src/lua/core/server.lua` writes the whole HTTP response with a single `send()` on the
client socket, which the server put into non-blocking mode (`client:settimeout(0)`), and then the
connection is closed. LuaSocket's `send` on a non-blocking socket writes only what fits into the
kernel send buffer and returns `nil, "timeout", last_byte_sent` for the rest. That partial result is
not handled, so a large reply (a full game state) is truncated and the client sees the connection
close early.

Same code on `main` (v1.5.2) and `dev`; no open issue or PR covers it (#190 and #196 are about
concurrent requests, not partial sends).

## Steps to Reproduce

1. Run several BalatroBot instances in parallel on a loaded machine (we saw it with two game
   containers plus a collector on an 8-vCPU Docker VM, `serve --headless --fast`).
2. Drive normal runs that return large game states (`play`, `gamestate` in the shop).
3. Occasionally the client gets `http.client.RemoteDisconnected: Remote end closed connection
   without response` (Python `urllib`), or a JSON decode error on a short body.

It is load-dependent: the slower the client reads, the more likely the reply does not fit the buffer.

## Expected Behavior

The whole response is delivered, however large.

## Actual Behavior

The response is cut off at whatever fit into the send buffer; the rest is dropped.

## Suggested Fix

Smallest change (what we run, as a patch in our container image; we have not seen a cut-off reply
in about 50 container runs since):

```lua
BB_SERVER.client_socket:settimeout(5)
local _, err = BB_SERVER.client_socket:send(response_str)
```

This blocks the game loop for at most 5 s if the client stops reading. If that is not acceptable, the
alternative is to keep the unsent tail (`send(data, last + 1)`) and finish it on the next update ticks
before closing the socket.

## Environment

- BalatroBot 1.5.2 (and `dev` at 2026-07-28), Balatro 1.0.1o, Steamodded 1.0.0~BETA-1814a
- Linux container (Fedora 42, LÖVE 11.5), Python client with `urllib`

## Files

- `src/lua/core/server.lua` (`send_raw`)

---
Before filing: contributing guide asks for Conventional Commit style (issues use it in titles too),
one change per PR, `make quality`, and both `pytest -n 6 tests/lua` and `pytest tests/cli` passing.
New work goes to the `dev` branch (BalatroBot 2.0); the maintainer asked for that on #164.
