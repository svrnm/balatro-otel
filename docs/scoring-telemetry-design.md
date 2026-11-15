# Scoring telemetry

Implemented in mod version and registry schema 0.3.0. The generated
[signal reference](scoring-signals.md) lists attributes and metric dimensions.

The signals answer which cards were evaluated, what they returned, which calculations explicitly
reported a trigger, and how effect handling changed chips and mult. They describe observed execution;
they do not measure what would have happened without a Joker or assign causal shares of a score.

## Signal boundaries

OpenTelemetry distinguishes operations with duration (spans), properties of those operations
(attributes), and individual occurrences (named log events). This instrumentation follows that
[guidance](https://opentelemetry.io/docs/specs/semconv/general/events/).

| Concept | Meaning | Signal |
| --- | --- | --- |
| Evaluation | One `eval_card` invocation during synchronous hand scoring | `balatro.card.evaluate` span and `balatro.card.evaluations` counter |
| Returned effects | Nonempty primary/post return tables, not proof of application | Evaluation attributes; numeric fields in `balatro.card.effect.*` and `balatro.card.post_effect.*` |
| Reported trigger | Exactly `true` in the second return value of `Card.calculate_joker` | `balatro.card.trigger` log event and `balatro.card.triggers` counter |
| Copied effects | `SMODS.blueprint_effect` returned a nonempty effect table | `balatro.card.copy` log event, with copied-card and copier identities |
| Effect handling | A completed `SMODS.calculate_individual_effect` invocation | `balatro.effect` log event and `balatro.effects` counter |
| Score mutation | Chips/mult immediately before and after a handler | Effect attributes |
| Joker retrigger execution | Truthy `context.retrigger_joker`, including card-valued references | Evaluation/trigger attributes |

All evaluations count, including fast empty evaluations whose spans are omitted. Spans retain the
existing rule: keep nonempty primary/post results or evaluations longer than 1 ms. A nonempty result
is not a confirmed trigger. An accepted effect is not necessarily a nonzero score mutation.

A trigger event records an explicit engine report, not a universal definition of activation.
Vanilla/effect-only returns may produce scoring effects without reporting this flag. Zero reported
triggers therefore does not mean Jokers did nothing. Do not derive a universal activation rate from
these two counters: their call boundaries differ, especially for nested/copy calculations.

## Card identity and properties

Evaluation and trigger observations snapshot card state at calculation entry: center key, set,
area, base rank/suit, enhancement center, edition, seal, and debuffed state. State changed during the
calculation does not rewrite that snapshot.

A weak-key table assigns IDs to live card objects without modifying game objects or saves. Two
copies of the same Joker have distinct IDs. Correlate IDs with `session.id`; they do not survive
reloads and are not deck positions.

Base rank/suit do not claim effective scoring rank/suit for wild, stone, or modded cards.
`balatro.card.enhancement` records the center when the set is Enhanced, not every dynamic enhancement.
Edition keys come from the edition table; legacy vanilla flags normalize to `e_foil`, `e_holo`,
`e_polychrome`, or `e_negative`. Missing enhancement/edition/seal values are omitted. Custom edition
shapes without a key or a recognized vanilla flag remain unknown.

No ability tables or complete context objects are serialized. Property getters are deliberately
not called: `SMODS.get_enhancements`, for example, can run additional game calculations.

## Attribution and context

The source is `effect.card` when explicitly supplied. The target is the `scored_card` argument.
Source IDs/keys use `balatro.effect.source_card.*`; target fields use `balatro.effect.target.*`.
The legacy `balatro.effect.source` display name retains its target fallback. The new
`balatro.effect.attribution` says `explicit`, `target_fallback`, or `unknown`, so a target fallback
cannot silently establish a known producer.

`SMODS.calculate_effect_table_key` identifies the component as `joker`, `playing_card`,
`enhancement`, `edition`, or `seal`. Edition-origin calls are also recognized from `from_edition`.
Other paths remain `unknown`; property presence does not establish property activation.

Boolean context flags remain available for detailed analysis. Copy detection uses `blueprint` or
`blueprint_card`; a card-valued `blueprint_card` supplies a related instance ID. A card-valued
`retrigger_joker` supplies the retrigger source ID. Because Blueprint/Brainstorm can call Joker
calculations without going through `eval_card`, `balatro.card.copy` also observes their helper
directly: card identity describes the copied card, and copy-source identity describes the copier.
Empty/blocked helper returns do not emit a copy event. This does not increment the trigger counter.
Requested repetition counts are not counted as
executed retriggers. These references report engine context, not an inferred dependency graph.

## Ordering and outcomes

Each handler gets a sequence number at entry, local to the scoring span. Nested handlers also
reference their enclosing sequence. Events are emitted at handler completion, so event timestamp
order may differ from entry order. Outer before/after changes include nested changes: summing both
as independent contributions would double count.

Outcomes classify handler returns: `true`, strings, and tables are `handled`; `false` is `unhandled`;
other returns, including `nil`, are `unknown`. This is evidence about the handler contract, not proof
of a visible effect. Original arguments, all return values (including nil positions), and errors are
preserved. Aborted scoring state resets at the next scoring operation.

Version 0.3.0 extends `balatro.effect` to nonnumeric arguments too. `balatro.effect.amount` is present
only for finite numbers; numeric counts and chips/mult retain the exporter's big-number omission
policy. Historical events lacked outcome evidence; they cannot be reinterpreted as confirmed
successful applications. Function callbacks and other nonnumeric amounts are never serialized.

## Metrics and scope

Counters are cumulative since launch. Their dimensions are deliberately limited:

- `balatro.card.evaluations`: area, one of four normalized values.
- `balatro.card.triggers`: boolean Joker retrigger-execution flag.
- `balatro.effects`: component and outcome, at most 18 combinations.

IDs, display names, definition keys, seeds, sequences, arbitrary context combinations, and property
combinations remain on traces/events. The exporter has no automatic SDK cardinality protection, so
these bounds limit local state as well as backend series. See
[OTel cardinality guidance](https://opentelemetry.io/docs/specs/otel/metrics/sdk/#cardinality-limits).
Per-Joker definition metric labels are intentionally deferred; detailed breakdowns use spans/events.

Everything added here is scoped to synchronous hand scoring. Economy, discard, shop, and end-of-round
activations outside that scope are not covered. Custom mods can bypass these hooks. Errors aborting
a calculation need not produce a completion event.

## Registry and verification

Definitions live in `telemetry/registry`, retaining semconv v1.44.0 and Weaver v0.28.0. Released
semconv groups were checked using the installed `otel-semantic-conventions` lookup; these game-domain
concepts use the existing `balatro.*` namespace. No upstream HTTP/DB/RPC conventions are redeclared.
The source/target and before-state names avoid leaf/namespace collisions detected by live-check.

CI runs registry check, hook/exporter tests, live-check on their actual exported payloads, generated
reference drift detection, and a schema diff against the base commit. `telemetry/weaver_samples.py`
adapts this exporter's OTLP/JSON to Weaver's file sample format; it is not a general OTLP converter.
The existing container runner tests real OTLP delivery via Collector and Weaver.

The trigger-return and effect-table contracts were inspected in the pinned Steamodded
`1.0.0-beta-1814a` source and the installed source. Behavioral tests cover explicit triggers without
numeric effects, effect-only returns, primary/post results, duplicate instances, property snapshots,
copy/retrigger references, nested effects, outcomes, missing numeric values, observer failure, and
original return/error preservation. A full gameplay compatibility matrix for newer Steamodded/mod
combinations remains outside this validation.

Weaver checks structure and conventions. Controlled tests and gameplay checks establish behavior;
schema validity alone cannot establish correct attribution or score accounting.

The implementation used the [semantic conventions skill](https://github.com/ollygarden/opentelemetry-agent-skills/tree/main/skills/otel-semantic-conventions)
and [Weaver skill](https://github.com/ollygarden/opentelemetry-agent-skills/tree/main/skills/otel-weaver).
The telemetry emissions skill was inspected but its inventory does not cover this custom mod.

## Verification record

Validated with the runner's LuaJIT and pinned Steamodded, Weaver v0.28.0, and semconv v1.44.0:

- Exporter and scoring-hook suites pass, including ordered post effects and copied-effect events.
- Registry check and live-check of both suites' exported payloads pass with zero violations.
  A negative fixture with an integer card-instance ID is rejected, verifying the validation gate.
- The BLUE/WHITE run `J00001` passes consistency checks: five blinds score-checked and one forced.
- The retrigger scenario records glass, polychrome, red-seal properties and three copied-effect
  events identifying Hanging Chad and Brainstorm, with distinct copier/copied IDs. Weaver reports
  zero violations and the mod reports no hook failures.
- The RED/WHITE run `C00001` exposes three Psychic score mismatches. The unchanged HEAD mod produces
  the same mismatches on the same seed; these are not introduced by the scoring hooks.
- The retrigger scenario's aggregate consistency command exits nonzero because its legitimate
  large score exceeds the checker's `FORCED_SCORE` threshold, leaving no score-checked blinds.
  Its gameplay, signal validation, and property/copy observations pass; it is not reported as a
  complete consistency-suite pass.

Weaver skill verification contract:

- [x] Manifest uses `definition_manifest/2.0` and versioned schema URL ending in `0.3.0`.
- [x] Every local definition and enum member declares stability (also checked independently).
- [x] Local attributes, metrics, spans and events use `balatro.*`.
- [x] No upstream boundary-domain definitions are duplicated locally.
- [x] Counter names have no `_total` suffix.
- [x] Duration histograms retain seconds as their unit.
- [x] Templates use the v2 grouped helpers and the resolved schema shape was inspected first.
- [~] Generated language-code formatting is not applicable: generation produces Markdown only.
  Generated reference whitespace is clean; the Python adapter passes the pinned Ruff formatter.
- [x] CI runs registry check, generation with a clean diff check, live-check, and baseline diff.
  Local CI-equivalent generation produces identical reference content.
- [x] Changed files were re-read and checked with `git diff --check`.
- [x] Remaining scope, compatibility limits, and pre-existing/harness failures are stated above.
