# Filed as coder/balatrobot#244 (2026-10-30)

**Title:** fix(lua.endpoints): start fails on current Steamodded, `G.GAME.viewed_back` is nil

## Description

On current Steamodded `main` (26.1026.0~dev-b, 2026-10-29), `start` fails with:

```
[SMODS balatrobot "src/lua/endpoints/start.lua"]:193: attempt to index field 'viewed_back' (a nil value)
```

(line 116 on v1.5.2). `start` calls `G.FUNCS.setup_run({ config = {} })` and then
`G.GAME.viewed_back:change_to(deck_data)`. In vanilla, `viewed_back` is created by the run-setup UI;
Steamodded's reworked run select (around smods#1560/#1571, September 2026) no longer creates it on
that path.

Not yet checked: which Steamodded release first breaks (26.829.0 or 26.1002.0).

## Steps to Reproduce

1. Install Steamodded `main` and BalatroBot `dev` (or v1.5.2).
2. `start` with any deck and stake, e.g. `{"deck": "b_red", "stake": "stake_white", "seed": "PSY00008"}`.

## Expected Behavior

A new run starts with the requested deck.

## Actual Behavior

`INTERNAL_ERROR` from the error above; no run starts.

## Suggested Fix

What we used to get past it (only ever with the Red deck, so whether the deck choice still reaches the
run on new Steamodded is untested):

```lua
G.GAME.viewed_back = G.GAME.viewed_back or Back(deck_data)
G.GAME.viewed_back:change_to(deck_data)
```

A proper fix probably sets the deck the way Steamodded's new run select does.

## Environment

- BalatroBot `dev` (2026-07-28) and v1.5.2, Steamodded `main` 26.1026.0~dev-b, Balatro 1.0.1o
- Linux container (Fedora 42, LÖVE 11.5)

## Files

- `src/lua/endpoints/start.lua`

---
Not part of this issue (a different bug we also hit, already reported as #233): `skip` hangs when
a skip tag opens a booster pack. This `start` failure is not reported yet (checked 2026-10-30).
