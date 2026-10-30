# Known Balatro issues to reproduce

Research round 2026-10-29: real bugs reported for Balatro (mostly the developer's official bug thread on
Steam) plus what our own runs found, ranked by how well we can trigger them with BalatroBot
(`add` spawns jokers/consumables/vouchers/packs/cards with seals, editions and enhancements; `set`
changes money, chips, ante, round, hands, discards; `use`, `rearrange`, `save`/`load`, `menu`) and
what the telemetry should show. Reports rarely name a version; "unverified" means not yet tried on
our 1.0.1o + Steamodded beta-1814a.

## Crashes

| # | Issue | Trigger via BalatroBot | Expected telemetry | Effort |
|---|---|---|---|---|
| C1 | **Perkeo + Wheel of Fortune crash on leaving the shop.** Perkeo copies a random consumable when the shop ends; copying Wheel of Fortune crashes. Several players reproduced it "consistently ... by pressing next round". [Steam thread](https://steamcommunity.com/app/2379780/discussions/0/4346606879507220901) | in SHOP: `add j_perkeo`, `add c_wheel_of_fortune`, `next_round` | `app.crash` in `SHOP`, failed `balatro.shop`/`balatro.run` spans, crash counter | easy |
| C2 | **The Cerulean Bell with an empty hand.** Hand empty but hands left (whole deck played/discarded) on Cerulean Bell (forces a card selected) → "attempt to index a nil value". [bug thread #544](https://steamcommunity.com/app/2379780/discussions/0/6234751259567432666/?ctp=37) | Cerulean Bell (`bl_final_bell`) is a finisher boss, so only on ante 8: `set ante 8`, `add v_directors_cut` and reroll the boss until it appears, then `set discards` high and discard until the deck is empty, keeping hands | `app.crash` in `SELECTING_HAND`/`DRAW_TO_HAND`, failed `balatro.blind` | medium (getting the boss) |
| C3 | **Stale save after the mod set changed** (found by us on day 1): continuing a run saved with Cryptid/Talisman after disabling them crashes on card hover, `card.lua:881: attempt to perform arithmetic on field 'perma_x_chips'`. | `save` with extra mods, restart without them, `load`, hover/score a card | `app.crash` right after a resumed run (`balatro.run.resumed=true`) | medium (two launches) |
| C4 | **Crash on "New Run" after entering Endless mode**, then the save is wiped (tutorial again, stats gone). [bug thread #545](https://steamcommunity.com/app/2379780/discussions/0/6234751259567432666/?ctp=37) | `set ante 8`, win the run (`set chips`), continue into endless, `menu`, `start` | `app.crash` near `balatro.run` start, `run.won` before it; next session: missing history | medium |
| C5 | **Reroll boss on the pack screen**: crash, then the reloaded pack is empty and Skip is disabled (softlock). [bug thread #542](https://steamcommunity.com/app/2379780/discussions/0/6234751259567432666/?ctp=37) | `add v_directors_cut`, open a pack, reroll boss while it is open; BalatroBot may refuse the reroll in that state | `app.crash` in a pack state, then a pack span that never ends | hard (API may not allow it) |
| C6 | **Random `engine/sprite.lua:96: attempt to index a nil value`** after ~30 min (also `engine/text.lua:235`), no mods; one report with Traditional Chinese. [#629](https://steamcommunity.com/app/2379780/discussions/0/6234751259567432666/?ctp=42), [#668](https://steamcommunity.com/app/2379780/discussions/0/6234751259567432666/?ctp=45) | long soak (`container/run.sh RED:WHITE:30`), also with the language set to zh_TW | `app.crash` with the engine stack; when/after what it happens | easy to run, unknown odds |

## Softlocks and freezes

| # | Issue | Trigger | Expected telemetry | Effort |
|---|---|---|---|---|
| S1 | **Quit while a Spectral pack is open**: on return the cards cover Use/Skip, the run can't continue. [#674](https://steamcommunity.com/app/2379780/discussions/0/6234751259567432666/?ctp=45) | in SHOP `add p_spectral_normal_1`, buy/open it, `menu`, `load`/continue | `balatro.booster_pack` never ends; run with no progress; bot gets NOT_ALLOWED on `pack` | easy |
| S2 | **Drawing stops with cards left in the deck** after The Hanged Man destroyed 2 cards. [#546](https://steamcommunity.com/app/2379780/discussions/0/6234751259567432666/?ctp=37) | `add c_hanged_man`, `use` it on 2 cards, play on | today: nothing (we don't record deck/hand sizes) | easy trigger, **telemetry gap** |
| S3 | **Zero hand size made a booster pack unskippable** (fixed in 1.0.1f; regression test). [known issues](https://ingamenews.com/games/balatro/issuesandfixes/known-issues-and-workarounds/) | reduce hand size to 0 (e.g. several `c_ectoplasm`), open a pack | pack span ends with `skipped=true` if fixed | medium |

## Wrong game behavior (scoring and rules)

| # | Issue | Trigger | Expected telemetry | Effort |
|---|---|---|---|---|
| W1 | **The Mouth adds chips outside the hand scores** (found by us, seen twice): blind total 60 chips above the sum of its hands; no public report found. | replay the seeds where it happened (C10002 BLUE/RED and RED/WHITE) | `balatro.hand.blind_score_added` != `balatro.hand.score`; `check_traces.py` score mismatch | reproduced, see Results |
| W2 | **The Idol on The Psychic triggered only on the 10** of a Hearts flush (K Q 10 7 6). [#620](https://steamcommunity.com/app/2379780/discussions/0/6234751259567432666/?ctp=42) | `add j_idol` (target card is random per round), get The Psychic, play the hand | `balatro.effect` events per card show which cards gave x-mult | medium |
| W3 | **Negative Eight Ball made no Tarot cards** for ~12 scored 8s. [#665](https://steamcommunity.com/app/2379780/discussions/0/6234751259567432666/?ctp=45) | `add j_8_ball edition=NEGATIVE`, play hands of 8s | `balatro.card.evaluate` effects vs. consumables gained (needs a consumable-created event: gap) | medium |
| W4 | **Duplicate cards in pack choices / two copies of one joker** without Showman. [#628](https://steamcommunity.com/app/2379780/discussions/0/6234751259567432666/?ctp=42) | many shops/packs in a soak | rule: two `balatro.card.buy`/`use` events with the same joker key in a run without Showman (`j_ring_master`) | easy (checker rule) |
| W5 | **naneinf**: past ~1e308 the score becomes NaN and can never beat the blind, so the run ends. [Balatro University via setsideb](https://setsideb.com/?p=9384) | `set chips` near 1e308 and play, or a scaling build | exporter drops non-finite doubles (attribute missing), `balatro.score` skips; makes our "inf/NaN" handling visible | easy |

## Performance and resources

| # | Issue | Trigger | Expected telemetry | Effort |
|---|---|---|---|---|
| P1 | **Very long scoring with stacked retriggers** (Red Seal, Sock and Buskin, Hanging Chad, Blueprint/Brainstorm copies); players speed it up with Cheat Engine. [Steam thread](https://steamcommunity.com/app/2379780/discussions/0/604155219069118124) | `add` the jokers and red-seal cards, play one hand | long `balatro.hand` (animation) and `balatro.hand.scoring`, many `balatro.card.evaluate` spans, event queue length, jank | easy |
| P2 | **RAM/VRAM climbing until a crash**, often with Discord screen sharing; "requested more GPU memory than is available". [thread](https://steamcommunity.com/app/2379780/discussions/0/604143843941548357), [#666](https://steamcommunity.com/app/2379780/discussions/0/6234751259567432666/?ctp=45) | long soak in render mode; texture memory and Lua heap over runs | `balatro.render.texture_memory.used`, `balatro.lua.memory.live` per run | easy to run; Discord not reproducible |
| P3 | **Stutter on Windows/Steam Deck** (engine; fixed in 1.0.1f by a LÖVE update). | not reproducible in our Linux container | frame time / jank in real-play sessions only | n/a |

## Not worth chasing here

Launch/display/audio problems (black or white screen, OpenGL window errors, washed-out colours, no
sound) depend on the player's GPU, drivers and overlays; save-data loss without a trigger; text bugs.
They happen before or outside the game loop our mod sees.

## Results (2026-10-29, 1.0.1o + Steamodded beta-1814a)

Reproduced with `telemetry/scenarios.py` (in a container: `telemetry/container/run.sh RED:WHITE:1::<scenario>`).

| Scenario | Outcome |
| --- | --- |
| `perkeo` (C1) | **Fixed in 1.0.1o.** No crash; Perkeo made a Negative copy of Wheel of Fortune. Kept as a regression test. |
| `spectral` (S1) | **Not reproducible through the API.** After `load` the pack is open and `pack skip` works. The reported bug is visual (cards covering the buttons), which the bot does not go through. |
| `mouth` (W1) | **Reproduced, root cause found (Steamodded).** Seed C10002 BLUE/RED: blind total 2820 vs hands 2760. The score added to the blind comes from `SMODS.calculate_round_score()`, i.e. `SMODS.Scoring_Parameters.*.current`; the debuffed-hand branch only zeroes the `hand_chips`/`mult` globals, so a hand The Mouth debuffs still adds its base chips × mult (Pair: 10×2 = 20, on 3 hands = 60). Steamodded main has the same code. Not specific to The Mouth: the soak on 2026-10-29 hit it with The Psychic (seed W110002, BLACK/RED), so any debuffed hand leaks. On video: `telemetry/evidence/psychic-debuffed-pair-adds-score.mp4` (`RECORD=1 SERVE_ARGS=--no-headless telemetry/container/run.sh RED:WHITE:1::psychic`). Vanilla 1.0.1o checked by hand: round score stays 0. Exact cause: `lovely/scoring_calculation.toml` sets `Scoring_Parameters.*.current` from the hand preview (`CardArea:parse_highlighted`, before its `update_hand_text`), and the debuffed branch of `evaluate_play` only zeroes the globals (`better_calc.toml`'s patch there just clears `SMODS.displayed_hand`), so `calculate_round_score()` adds the previewed base. **Already fixed upstream** by smods#1441 ("psychic, eye, mouth scoring bugfix", merged 2026-07-11, released in 26.829.0): `mod_mult`/`mod_chips` now also sync `Scoring_Parameters` when they differ from the new value. That also explains why the first blocked hand of a round added 0 on beta-1814a: its sync ran only when the global changed (`_mult ~= mult`), so the first `mod_mult(0)` synced, and later ones, with the global already 0, did not. Checked on smods main + BalatroBot dev (seed PSY00008): both blocked Pairs add 0. Nothing to report; our container pins beta-1814a because BalatroBot 1.5.2 cannot start runs on newer smods (`G.GAME.viewed_back` is nil, coder/balatrobot#244). The same root cause explains the soak's other mismatches: **The Flint** (the blind got the unhalved mult, e.g. Flush 64×2=128 shown, 256 added) matches on smods main; **The House/Wheel/Mark** (face-down cards skip the preview, so the parameters keep stale values: W810002 Pair 44→22, 32→16, 28→0) vanish when #1441's two lines are applied to beta-1814a (A/B on seeds W810002, W2000001, W2210002: 5 mismatches unpatched, 0 patched). Shows up as `balatro.hand.score = 0` with `balatro.hand.blind_score_added > 0` (Grafana "Known issues" row, Bronto "Score mismatches" widget and monitor, `check_traces.py`). |
| `retrigger` (P1) | **Measured.** Baseline hand: scoring 0.9 ms, 8 `balatro.card.evaluate`, hand 0.23 s. Retrigger build (5 jokers, 5 red-seal glass polychrome face cards): scoring 5.6 ms, 46 evaluations, hand 2.2 s in fast mode, event queue peak 257, score 6.15e13. No jank headless (nothing is drawn); run it with the `render` chaos mode for frame timing. |
| W5, C2, C3 | Not done. `set chips` cannot push a score past 1e308, so naneinf needs a real scaling build. |

Telemetry gaps still open: deck/hand size and draws (S2), consumables created (W3), "run made no
progress for N minutes" (S1).
