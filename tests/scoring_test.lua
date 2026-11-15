-- Hook behavior tests with the real exporter and controlled game calls; no game assets required.
-- SMODS_DIR supplies only Steamodded's JSON library, as in otel_test.lua.
local smods = os.getenv("SMODS_DIR") or (os.getenv("HOME") .. "/Library/Application Support/Balatro/Mods/smods")
package.path = smods .. "/libs/json/?.lua;mod/otel-trace/?.lua;" .. package.path
local otel = require "otel"
local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end
local function attrs(list)
  local out = {}
  for _, kv in ipairs(list) do
    local v = kv.value
    if v.stringValue ~= nil then out[kv.key] = v.stringValue
    elseif v.boolValue ~= nil then out[kv.key] = v.boolValue
    elseif v.doubleValue ~= nil then out[kv.key] = v.doubleValue
    else out[kv.key] = tonumber(v.intValue) end
  end
  return out
end
local function events(name)
  local out = {}
  for _, records in pairs(otel.logs) do
    for _, r in ipairs(records) do if r.eventName == name then out[#out + 1] = attrs(r.attributes) end end
  end
  return out
end
local function count(name)
  local total = 0
  for _, p in pairs(otel.metrics[name] and otel.metrics[name].points or {}) do total = total + p.asDouble end
  return total
end
local function last_evaluation()
  return attrs(otel.buffer[#otel.buffer].attributes)
end
local function card(k, set)
  return { config = { center = { key = k } }, ability = { name = "Duplicate Joker", set = set or "Joker" },
    base = { value = "Jack", suit = "Hearts" }, area = G.jokers }
end
G = { jokers = {}, play = {}, hand = {} }
Card, SMODS = {}, {}
local original_results
local primary = { jokers = { mult_mod = 4 } }
local post = { { edition = { x_mult = 1.5 } }, { jokers = { mult_mod = 4 } } }
function eval_card(c, context, marker)
  assert(marker == "argument", "extra arguments forwarded")
  if context.mutate then c.seal = "Gold" end
  if context.call_joker then c:calculate_joker(context) end
  return unpack(original_results, 1, original_results.n)
end
function Card:calculate_joker(context)
  if context.raise then error(context.raise, 0) end
  return context.result, context.reported, nil, "tail"
end
function SMODS.blueprint_effect(copier, copied, context)
  local old = context.blueprint_card
  context.blueprint_card = copier
  local ret = copied:calculate_joker(context)
  context.blueprint_card = old
  return ret, nil, "copy-tail"
end
function SMODS.calculate_effect_table_key(t, k, c, ret)
  ret.visited = true
  return SMODS.calculate_individual_effect(t[k], c, t.key or "mult", t.amount or 4, k == "edition")
end
function SMODS.calculate_individual_effect(effect, target, k, amount)
  if k == "nested" then
    SMODS.calculate_effect_table_key({ edition = effect, amount = 2 }, "edition", target, {})
    return true, nil, "tail"
  end
  if k == "mult" then mult = mult + amount; return true, nil, "tail" end
  if k == "func" then amount(); return true end
  if k == "unsupported" then return nil end
  if k == "rejected" then return false end
  if k == "raise" then error(amount, 0) end
  return true
end
-- Property observation must not execute engine getters.
function SMODS.get_enhancements() error("instrumentation must not call this") end
local span
require("scoring").install(otel, function() return span end)
local c1, c2 = card("j_joker"), card("j_joker")
setmetatable(c1, { __index = Card }); setmetatable(c2, { __index = Card })
original_results = pack(primary, post, nil, "tail")
local before = #otel.buffer
local r = pack(eval_card(c1, {}, "argument"))
assert(r.n == 4 and r[1] == primary and r[2] == post and r[3] == nil and r[4] == "tail")
assert(#otel.buffer == before and count("balatro.card.evaluations") == 0, "outside scoring is untouched")

span = otel.start("balatro.hand.scoring")
c1.edition, c1.seal, c1.debuff = { polychrome = true }, "Red", true
r = pack(eval_card(c1, { joker_main = true, mutate = true }, "argument"))
assert(r.n == 4 and r[1] == primary and r[2] == post and r[4] == "tail")
local a1 = last_evaluation()
assert(a1["balatro.card.edition"] == "e_polychrome" and a1["balatro.card.seal"] == "Red", "entry snapshot")
assert(a1["balatro.card.debuffed"] == true and a1["balatro.card.rank"] == "Jack" and a1["balatro.card.suit"] == "Hearts")
assert(a1["balatro.card.effect.jokers.mult_mod"] == 4 and a1["balatro.card.post_effect.1.edition.x_mult"] == 1.5)
assert(a1["balatro.card.post_effect.2.jokers.mult_mod"] == 4)
assert(a1["balatro.card.evaluation.has_post_effects"] == true)
eval_card(c2, {}, "argument")
local a2 = last_evaluation()
assert(a1["balatro.card.instance.id"] ~= a2["balatro.card.instance.id"], "duplicate Jokers have distinct identities")
eval_card(c1, { blueprint_card = c2, retrigger_joker = c2 }, "argument")
local a3 = last_evaluation()
assert(a3["balatro.card.instance.id"] == a1["balatro.card.instance.id"])
assert(a3["balatro.card.evaluation.copy_source.id"] == a2["balatro.card.instance.id"])
assert(a3["balatro.card.evaluation.retrigger_source.id"] == a2["balatro.card.instance.id"])
assert(a3["balatro.card.evaluation.retrigger"] and a3["balatro.card.evaluation.copy"])

local playing = card("m_glass", "Enhanced")
playing.area, playing.edition, playing.seal = G.play, { key = "e_custom" }, "Purple"
eval_card(playing, { repetition = true }, "argument")
assert(last_evaluation()["balatro.card.enhancement"] == "m_glass")
assert(last_evaluation()["balatro.card.edition"] == "e_custom")

-- Fast empty evaluations still count, while their spans remain omitted.
local clock = otel.now
otel.now = function() return 1000 end
original_results = pack({}, nil)
before = #otel.buffer
eval_card(c1, {}, "argument")
assert(#otel.buffer == before and count("balatro.card.evaluations") == 5)
otel.now = clock

-- Effect-only returns are not classified as explicit trigger reports.
r = pack(c1:calculate_joker({ result = { mult = 4 } }))
assert(r.n == 4 and r[3] == nil and r[4] == "tail" and #events("balatro.card.trigger") == 0)
r = pack(c1:calculate_joker({ reported = true, retrigger_joker = c2 }))
assert(r.n == 4 and r[1] == nil and r[2] == true and count("balatro.card.triggers") == 1)
assert(events("balatro.card.trigger")[1]["balatro.card.evaluation.retrigger_source.id"] == a2["balatro.card.instance.id"])
-- Calling the trigger hook through eval_card emits only one trigger occurrence.
original_results = pack({}, {})
eval_card(c1, { call_joker = true, reported = true }, "argument")
assert(count("balatro.card.triggers") == 2)
-- Real copy helpers bypass eval_card and need their own occurrence evidence.
r = pack(SMODS.blueprint_effect(c1, c2, { result = { mult = 4 } }))
assert(r.n == 3 and r[2] == nil and r[3] == "copy-tail")
local copy = events("balatro.card.copy")[1]
assert(copy["balatro.card.instance.id"] == a2["balatro.card.instance.id"])
assert(copy["balatro.card.evaluation.copy_source.id"] == a1["balatro.card.instance.id"])
assert(count("balatro.card.triggers") == 2, "a copied effect is not an explicit trigger report")
SMODS.blueprint_effect(c1, c2, {})
assert(#events("balatro.card.copy") == 1, "empty copy returns do not report a copied effect")

hand_chips, mult = 100, 10
r = pack(SMODS.calculate_individual_effect({ card = c1 }, playing, "mult", 4, false))
assert(r.n == 3 and r[1] == true and r[2] == nil and r[3] == "tail" and mult == 14)
local e = events("balatro.effect")[1]
assert(e["balatro.score.before.mult"] == 10 and e["balatro.score.mult"] == 14)
assert(e["balatro.effect.source_card.instance.id"] == a1["balatro.card.instance.id"])
assert(e["balatro.effect.target.instance.id"] ~= e["balatro.effect.source_card.instance.id"])
assert(e["balatro.effect.attribution"] == "explicit" and e["balatro.effect.component"] == "unknown")
for _, k in ipairs({ "jokers", "playing_card", "enhancement", "edition", "seals" }) do
  local ret = {}
  SMODS.calculate_effect_table_key({ [k] = {}, amount = 2 }, k, playing, ret)
  assert(ret.visited)
end
local ev = events("balatro.effect")
assert(ev[2]["balatro.effect.component"] == "joker" and ev[4]["balatro.effect.component"] == "enhancement")
assert(ev[5]["balatro.effect.component"] == "edition" and ev[5]["balatro.effect.from_edition"])
assert(ev[6]["balatro.effect.component"] == "seal")
assert(ev[6]["balatro.effect.attribution"] == "target_fallback" and ev[6]["balatro.effect.source_card.instance.id"] == nil)
SMODS.calculate_individual_effect({}, playing, "nested", 1, false)
ev = events("balatro.effect")
assert(ev[7]["balatro.effect.parent_sequence"] == ev[8]["balatro.effect.sequence"], "nested entry ordering")
assert(ev[7]["balatro.effect.sequence"] > ev[8]["balatro.effect.sequence"])
SMODS.calculate_individual_effect({}, playing, "unsupported", 1)
SMODS.calculate_individual_effect({}, playing, "rejected", 1)
local called = false
SMODS.calculate_individual_effect({}, playing, "func", function() called = true end)
assert(called)
ev = events("balatro.effect")
assert(ev[9]["balatro.effect.outcome"] == "unknown" and ev[10]["balatro.effect.outcome"] == "unhandled")
assert(ev[11]["balatro.effect.amount"] == nil and ev[11]["balatro.effect.outcome"] == "handled")
assert(count("balatro.effects") == #ev)

-- A broken observation cannot change the game result or drop extra return values.
local event = otel.event
otel.event = function() error("observer failure") end
r = pack(SMODS.calculate_individual_effect({}, playing, "mult", 1))
assert(r.n == 3 and r[3] == "tail")
otel.event = event
-- Original errors retain their identity; a fresh scoring span resets any aborted nesting.
local sentinel = {}
local ok, err = pcall(SMODS.calculate_individual_effect, {}, playing, "raise", sentinel)
assert(not ok and err == sentinel)
otel.finish(span)
span = otel.start("balatro.hand.scoring")
SMODS.calculate_individual_effect({}, playing, "mult", 1)
ev = events("balatro.effect")
assert(ev[#ev]["balatro.effect.sequence"] == 1 and ev[#ev]["balatro.effect.parent_sequence"] == nil)
otel.finish(span)
span = nil
-- Only documented, finite dimensions reach metric state, regardless of custom card identities.
for name, m in pairs(otel.metrics) do
  for _, p in pairs(m.points) do
    local a = attrs(p.attributes)
    assert(a["balatro.card.instance.id"] == nil and a["balatro.card.key"] == nil)
    assert(a["balatro.card.evaluation.context"] == nil and a["balatro.run.seed"] == nil)
  end
end
-- Remove the deliberate observer-failure warning from validation fixtures.
otel.logs["balatro-otel-trace"] = (function()
  local records, warnings = {}, 0
  for _, rec in ipairs(otel.logs["balatro-otel-trace"]) do
    if rec.eventName then records[#records + 1] = rec
    else
      warnings = warnings + 1
      assert(rec.body.stringValue:find("observer failure", 1, true), "unexpected hook failure")
    end
  end
  assert(warnings == 1, "exactly the deliberate observer failure was logged")
  return records
end)()
if arg[1] then
  local function write(name, body)
    local f = assert(io.open(arg[1] .. "/" .. name .. ".json", "w")); f:write(body); f:close()
  end
  write("scoring-traces", otel.encode(otel.buffer))
  write("scoring-logs", otel.encode_logs(otel.logs))
  write("scoring-metrics", otel.encode_metrics())
end
io.stderr:write("ok: card identity, properties, evaluations, triggers, effect attribution/order/outcomes, return and error preservation\n")
