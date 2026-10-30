-- Offline check of otel.lua: builds sample spans, events, logs and metrics with registry names,
-- asserts their OTLP shape, and writes <dir>/traces.json, logs.json, metrics.json for posting to
-- a collector (and from there to `weaver registry live-check`, see README).
-- Usage: lua test.lua <dir>
package.path = os.getenv("HOME") .. "/Library/Application Support/Balatro/Mods/smods/libs/json/?.lua;"
  .. "otel-trace/?.lua;" .. package.path
local otel = require "otel"
local json = require "json"
local D = otel.double

local function by_key(list)
  local t = {}
  for _, kv in ipairs(list) do t[kv.key] = kv.value end
  return t
end

-- Resource and common attributes ------------------------------------------------------------
local session = otel.uuid()
assert(session:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"), session)
otel.resource["service.version"] = "1.0.1o-FULL"
otel.resource["service.instance.id"] = session
otel.resource["os.type"] = "darwin"
otel.common["session.id"] = session
otel.common["balatro.run.seed"] = "TEST1234"

-- Traces ------------------------------------------------------------------------------------
local run = otel.start("balatro.run", { ["balatro.deck.name"] = "Red Deck", ["balatro.stake"] = 1, ["balatro.run.resumed"] = false })
local blind = otel.start("balatro.blind", { ["balatro.blind.name"] = "Small Blind", ["balatro.ante"] = 1 }, run)
local hand = otel.start("balatro.hand", { ["balatro.hand.card_count"] = 5 }, blind)
local scoring = otel.start("balatro.hand.scoring", nil, hand)
otel.finish(otel.start("balatro.card.evaluate", {
  ["balatro.card.name"] = "Greedy Joker",
  ["balatro.card.key"] = "j_greedy_joker",
  ["balatro.card.area"] = "jokers",
  ["balatro.card.evaluation.context"] = "cardarea,individual",
  ["balatro.card.effect.jokers.mult_mod"] = D(3),
}, scoring, 1000.5), nil, nil, 1000.75)
otel.event("balatro.effect", {
  ["balatro.effect.key"] = "mult", ["balatro.effect.amount"] = D(3), ["balatro.effect.source"] = "Greedy Joker",
  ["balatro.score.chips"] = D(40), ["balatro.score.mult"] = D(7),
}, scoring)
otel.finish(scoring)
otel.finish(hand, {
  ["balatro.hand.type"] = "Flush", ["balatro.hand.chips"] = D(75), ["balatro.hand.mult"] = D(4),
  ["balatro.hand.score"] = D(1 / 0), -- Talisman-sized: left out, not sent as the wrong type
})
otel.event("balatro.discard", { ["balatro.discard.card_count"] = 3 }, blind)
otel.event("app.jank", {
  ["app.jank.frame_count"] = 1, ["app.jank.threshold"] = D(0.1), ["app.jank.period"] = D(0.25),
  ["balatro.game.state"] = "SELECTING_HAND", ["balatro.frame.update.duration"] = D(0.01),
  ["balatro.frame.draw.duration"] = D(0.02), ["balatro.frame.other.duration"] = D(0.22),
  ["balatro.render.draw_calls"] = 350, ["balatro.event_queue.length"] = 4, ["balatro.lua.memory.used"] = 104857600,
}, blind, "WARN")
otel.finish(blind, {
  ["balatro.blind.target"] = D(300), ["balatro.blind.score"] = D(524), ["balatro.blind.won"] = true,
  ["balatro.frame.count"] = 3600, ["balatro.frame.average_rate"] = D(59.8), ["balatro.frame.max_duration"] = D(0.25),
  ["balatro.frame.jank_count"] = 1, ["balatro.lua.memory.used"] = 104857600,
})
local shop = otel.start("balatro.shop", { ["balatro.ante"] = 1 }, run)
otel.event("balatro.card.buy", {
  ["balatro.card.name"] = "Greedy Joker", ["balatro.card.key"] = "j_greedy_joker", ["balatro.card.set"] = "Joker",
  ["balatro.dollars"] = 1, ["balatro.card.cost"] = 5, ["balatro.shop.buy_and_use"] = false,
}, shop)
otel.event("balatro.shop.reroll", { ["balatro.shop.reroll_cost"] = 5, ["balatro.dollars"] = 1 }, shop)
local pack = otel.start("balatro.booster_pack", {
  ["balatro.card.name"] = "Arcana Pack", ["balatro.card.key"] = "p_arcana_normal_1", ["balatro.booster_pack.skipped"] = true,
}, shop)
otel.finish(pack)
otel.finish(shop, { ["balatro.dollars"] = 1 })
otel.event("app.crash", {
  ["app.crash.id"] = otel.uuid(), ["exception.message"] = "card.lua:881: attempt to perform arithmetic",
  ["exception.stacktrace"] = "stack traceback:\n\tcard.lua:881", ["balatro.game.state"] = "SHOP",
}, run, "FATAL")
otel.finish(run, { ["balatro.ante"] = 1, ["balatro.round"] = 1, ["balatro.dollars"] = 1, ["error.type"] = "lua_error" }, "crash")

local traces = otel.encode(otel.buffer)
local spans = {}
for _, s in ipairs(json.decode(traces).resourceSpans[1].scopeSpans[1].spans) do spans[s.name] = s end
local r, b, h, ev = spans["balatro.run"], spans["balatro.blind"], spans["balatro.hand"], spans["balatro.card.evaluate"]
assert(r.status.code == 2 and r.parentSpanId == nil and #r.traceId == 32 and #r.spanId == 16)
assert(b.parentSpanId == r.spanId and h.parentSpanId == b.spanId and ev.parentSpanId == spans["balatro.hand.scoring"].spanId)
assert(ev.startTimeUnixNano == "1000500000000" and ev.endTimeUnixNano == "1000750000000")
assert(ev.events == nil, "no span events (OTEP 4430)")
local ha, ba = by_key(h.attributes), by_key(b.attributes)
assert(ha["session.id"].stringValue == session and ha["balatro.run.seed"].stringValue == "TEST1234", "common attributes")
assert(ha["balatro.hand.card_count"].intValue == "5", "whole numbers are int64 strings")
assert(ha["balatro.hand.chips"].doubleValue == 75, "D() keeps doubles even when whole")
assert(ha["balatro.hand.score"] == nil)
assert(ba["balatro.frame.average_rate"].doubleValue == 59.8 and ba["balatro.blind.won"].boolValue == true)
assert(by_key(r.attributes)["error.type"].stringValue == "lua_error")
local res = by_key(json.decode(traces).resourceSpans[1].resource.attributes)
assert(res["telemetry.sdk.language"].stringValue == "lua" and res["os.type"].stringValue == "darwin")

-- Logs and events ---------------------------------------------------------------------------
otel.log("INFO", "Injected Blind in 0.03 ms", nil, nil, "TIMER")
local logs = otel.encode_logs(otel.logs)
local scopes = {}
for _, s in ipairs(json.decode(logs).resourceLogs[1].scopeLogs) do scopes[s.scope.name] = s.logRecords end
assert(scopes.TIMER and #scopes.TIMER == 1 and scopes.TIMER[1].body.stringValue:find("Injected"), "logger name is the scope")
local events = {}
for _, rec in ipairs(scopes["balatro-otel-trace"]) do events[rec.eventName] = rec end
assert(events["balatro.effect"].traceId == r.traceId and events["balatro.effect"].spanId == spans["balatro.hand.scoring"].spanId)
assert(events["balatro.effect"].body == nil and events["balatro.effect"].severityNumber == 9)
assert(events["app.crash"].severityNumber == 21 and by_key(events["app.crash"].attributes)["session.id"])

-- Metrics -----------------------------------------------------------------------------------
otel.count("balatro.hands", 1, "{hand}", { ["balatro.hand.type"] = "Flush" })
otel.count("balatro.hands", 2, "{hand}", { ["balatro.hand.type"] = "Flush" })
otel.count("balatro.hands", 1, "{hand}", { ["balatro.hand.type"] = "Pair" })
otel.count("balatro.score", 1 / 0, "{chip}") -- dropped, not encodable
otel.count("balatro.frame.janks", 1, "{frame}", { ["balatro.game.state"] = "SHOP" })
otel.gauge("balatro.frame.rate", 60, "{frame}/s")
otel.gauge("balatro.lua.memory.used", 104857600, "By")
for _, s in ipairs({ 0.001, 0.016, 0.016, 0.04, 2 }) do otel.histogram("balatro.frame.duration", s, "s") end
local metrics_body = otel.encode_metrics()
local metrics = {}
for _, m in ipairs(json.decode(metrics_body).resourceMetrics[1].scopeMetrics[1].metrics) do metrics[m.name] = m end
assert(metrics["balatro.score"] == nil)
assert(metrics["balatro.hands"].unit == "{hand}" and metrics["balatro.frame.duration"].unit == "s")
local per_type = {}
for _, p in ipairs(metrics["balatro.hands"].sum.dataPoints) do per_type[p.attributes[1].value.stringValue] = p.asDouble end
assert(per_type.Flush == 3 and per_type.Pair == 1, "counters accumulate per attribute set")
local hist = metrics["balatro.frame.duration"].histogram.dataPoints[1]
-- bounds 0.002,0.004,0.008,0.0167,0.0333,0.05,...,1 s: 0.001 -> b1, 0.016 -> b4 (x2), 0.04 -> b6, 2 -> overflow b11
assert(hist.count == "5" and hist.bucketCounts[1] == "1" and hist.bucketCounts[4] == "2"
  and hist.bucketCounts[6] == "1" and hist.bucketCounts[11] == "1" and hist.max == 2)

local dir = arg[1] or "."
local function write(name, s) local f = assert(io.open(dir .. "/" .. name, "w")); f:write(s); f:close() end
write("traces.json", traces)
write("logs.json", logs)
write("metrics.json", metrics_body)
io.stderr:write("ok: spans, events, logs, metrics; trace " .. r.traceId .. "\n")
