-- Balatro telemetry. Every name is defined in telemetry/registry (balatro.* conventions on top of
-- OTel semantic conventions v1.44.0) and validated with Weaver.
-- Traces: balatro.run -> balatro.blind -> balatro.hand -> balatro.hand.scoring -> balatro.card.evaluate
--         balatro.run -> balatro.shop -> balatro.booster_pack
-- Events (log records with an event name, linked to the open span): balatro.effect, balatro.discard,
--   balatro.card.{buy,sell,use,redeem}, balatro.shop.reroll, balatro.blind.skip, app.jank, app.crash,
--   session.start. Logs: Steamodded's logger, one scope per logger.
-- Metrics: frame time histograms, render and memory gauges, gameplay counters.
local otel = assert(SMODS.load_file("otel.lua"))()
local D = otel.double

local OS_TYPE = { ["OS X"] = "darwin", iOS = "darwin", Windows = "windows", Linux = "linux", Android = "linux" }
local instance_id = otel.uuid()
otel.resource["service.version"] = VERSION
otel.resource["service.instance.id"] = instance_id
otel.resource["os.type"] = OS_TYPE[love.system.getOS()] or love.system.getOS():lower()
otel.resource["balatro.smods.version"] = SMODS.version
otel.common["session.id"] = instance_id -- one session per game launch

-- Endpoint: OTEL_EXPORTER_OTLP_ENDPOINT wins (otel.lua reads it), then the in-game setting. The game's
-- text input can't type "/" and turns "0" into "o", so the setting is pasted from the clipboard.
local mod = SMODS.current_mod
local env_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
if not env_endpoint and mod.config.endpoint ~= "" then otel.endpoint = mod.config.endpoint end

G.FUNCS.otel_paste_endpoint = function()
  local url = (love.system.getClipboardText() or ""):match("^%s*(https?://[%w%-%._~:/%[%]@]+)%s*$")
  if not url then return play_sound("cancel") end
  mod.config.endpoint = url:gsub("/$", "")
  otel.endpoint = mod.config.endpoint
end

G.FUNCS.otel_reset_endpoint = function()
  mod.config.endpoint = ""
  otel.endpoint = "http://127.0.0.1:4318"
end

mod.config_tab = function()
  local function text(t, opts)
    local n = { n = G.UIT.T, config = { scale = 0.35, colour = G.C.UI.TEXT_LIGHT } }
    for k, v in pairs(opts or { text = t }) do n.config[k] = v end
    return { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = { n } }
  end
  local nodes = {
    text("Sends telemetry over OTLP/HTTP to"),
    text(nil, { ref_table = otel, ref_value = "endpoint", scale = 0.45, colour = G.C.FILTER }),
  }
  if env_endpoint then
    nodes[#nodes + 1] = text("(set by OTEL_EXPORTER_OTLP_ENDPOINT)")
  else
    nodes[#nodes + 1] = text("Copy a URL such as http://192.168.1.10:4318, then paste it here.")
    nodes[#nodes + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.1 }, nodes = {
      UIBox_button({ label = { "Paste from clipboard" }, button = "otel_paste_endpoint", minw = 3.5, colour = G.C.BLUE, col = true }),
      UIBox_button({ label = { "Reset to default" }, button = "otel_reset_endpoint", minw = 3.5, colour = G.C.RED, col = true }),
    } }
  end
  return { n = G.UIT.ROOT, config = { r = 0.1, minw = 8, align = "cm", padding = 0.2, colour = G.C.BLACK }, nodes = nodes }
end

print("[otel] loaded, session " .. instance_id .. ", exporting to " .. otel.endpoint)
local big = to_big or function(x) return x end -- Talisman defines to_big; vanilla compares plain numbers

local JANK_THRESHOLD = 0.1  -- seconds; longer frames emit app.jank
local SLOW_EVAL = 0.001     -- seconds; card evaluations this slow are kept even without an effect
local EXPORT_INTERVAL = 10  -- seconds between metric exports (which also flush spans and logs)

local run, blind, hand, scoring, shop, pack
local perf

local function innermost() return scoring or hand or pack or shop or blind or run end

-- A tracing bug must never crash the game (and lose the run), so every hook body is guarded.
local function safe(f, ...)
  local ok, err = pcall(f, ...)
  if not ok then
    print("[otel] " .. tostring(err))
    pcall(otel.log, "WARN", "otel hook failed: " .. tostring(err), nil, innermost())
  end
end

local function state_name()
  for name, v in pairs(G.STATES) do if v == G.STATE then return name end end
  return tostring(G.STATE)
end

-- Renderer, display and graphics settings, so performance can be compared across machines.
safe(function()
  local renderer, version, vendor, device = love.graphics.getRendererInfo()
  local w, h = love.graphics.getDimensions()
  local r = otel.resource
  r["balatro.renderer.name"], r["balatro.renderer.version"] = renderer, version
  r["balatro.renderer.vendor"], r["balatro.renderer.device"] = vendor, device
  r["balatro.display.width"], r["balatro.display.height"] = w, h
  r["balatro.display.dpi_scale"] = D(love.graphics.getDPIScale())
  r["balatro.settings.vsync"] = G.SETTINGS.WINDOW.vsync
  r["balatro.settings.screen_mode"] = G.SETTINGS.WINDOW.screenmode
  r["balatro.settings.texture_scaling"] = G.SETTINGS.GRAPHICS.texture_scaling
  r["balatro.settings.shadows"] = G.SETTINGS.GRAPHICS.shadows
  r["balatro.settings.crt"] = D(G.SETTINGS.GRAPHICS.crt)
  r["balatro.settings.bloom"] = G.SETTINGS.GRAPHICS.bloom
end)

safe(otel.event, "session.start") -- session.id comes from otel.common

local function card_name(card)
  if not card then return "?" end
  if card.ability and card.ability.set == "Joker" then return card.ability.name end
  if card.base and card.base.value then return card.base.value .. " of " .. card.base.suit end
  return card.ability and card.ability.name or "?"
end

-- Context is a bag of boolean flags (joker_main, individual, repetition, ...); keep the ones set.
local function context_flags(context)
  local t = {}
  for k, v in pairs(context) do if v == true then t[#t + 1] = k end end
  table.sort(t)
  return table.concat(t, ",")
end

-- eval_card returns { jokers = { mult_mod = 4, ... }, playing_card = { chips = 10 }, ... }
local function effect_attrs(ret, out)
  for source, effect in pairs(ret or {}) do
    if type(source) == "string" and type(effect) == "table" then
      for k, v in pairs(effect) do
        if type(k) == "string" and type(v) == "number" then out["balatro.card.effect." .. source .. "." .. k] = D(v) end
      end
    end
  end
  return out
end

-- Render stats reset when a frame is presented, so they are captured at the end of draw.
local frame_stats = {}

local function perf_reset()
  perf = {
    frames = 0, dt_sum = 0, dt_max = 0, slow = 0, mem_max = 0, queue_max = 0,
    update_sum = 0, update_max = 0, draw_sum = 0, draw_max = 0,
    drawcalls_max = 0, canvas_max = 0, shader_max = 0, texmem_max = 0,
  }
end
perf_reset()

local function perf_attrs()
  local frames = math.max(perf.frames, 1)
  return {
    ["balatro.frame.count"] = perf.frames,
    ["balatro.frame.average_rate"] = D(perf.frames / math.max(perf.dt_sum, 1e-9)),
    ["balatro.frame.max_duration"] = D(perf.dt_max),
    ["balatro.frame.jank_count"] = perf.slow,
    ["balatro.frame.update.average_duration"] = D(perf.update_sum / frames),
    ["balatro.frame.update.max_duration"] = D(perf.update_max),
    ["balatro.frame.draw.average_duration"] = D(perf.draw_sum / frames),
    ["balatro.frame.draw.max_duration"] = D(perf.draw_max),
    ["balatro.lua.memory.used"] = math.floor(collectgarbage("count") * 1024),
    ["balatro.lua.memory.max_used"] = math.floor(perf.mem_max * 1024),
    ["balatro.event_queue.max_length"] = perf.queue_max,
    ["balatro.render.max_draw_calls"] = perf.drawcalls_max,
    ["balatro.render.max_canvas_switches"] = perf.canvas_max,
    ["balatro.render.max_shader_switches"] = perf.shader_max,
    ["balatro.render.max_texture_memory"] = perf.texmem_max,
  }
end

local function end_blind(won)
  if not blind then return end
  local a = perf_attrs()
  a["balatro.blind.name"] = G.GAME.blind and G.GAME.blind.name
  a["balatro.blind.target"] = G.GAME.blind and D(G.GAME.blind.chips)
  a["balatro.blind.score"] = D(G.GAME.chips)
  a["balatro.blind.won"] = won
  otel.finish(blind, a)
  blind = nil
  otel.count("balatro.blinds", 1, "{blind}", { ["balatro.blind.won"] = won })
end

local function end_shop()
  if not shop then return end
  otel.finish(shop, { ["balatro.dollars"] = G.GAME.dollars })
  shop = nil
end

local function end_pack()
  if not pack then return end
  otel.finish(pack)
  pack = nil
end

local function end_run(outcome)
  if not run then return end
  end_pack()
  end_shop()
  end_blind(false)
  otel.finish(run, {
    ["balatro.run.outcome"] = outcome,
    ["balatro.ante"] = G.GAME.round_resets.ante,
    ["balatro.round"] = G.GAME.round,
    ["balatro.dollars"] = G.GAME.dollars,
  })
  run = nil
  otel.common["balatro.run.seed"] = nil
  otel.flush()
end

local start_run = Game.start_run
function Game:start_run(args)
  safe(end_run, "abandoned")
  local ret = start_run(self, args)
  safe(function()
    -- Lua's incremental GC rarely brings the heap down to what is live, so sampled memory cannot
    -- show a leak. One full collection per run start (a screen transition, not gameplay) gives the
    -- live heap; a leak shows as this rising from run to run.
    collectgarbage("collect")
    otel.common["balatro.run.seed"] = G.GAME.pseudorandom.seed
    run = otel.start("balatro.run", {
      ["balatro.deck.name"] = G.GAME.selected_back.name,
      ["balatro.stake"] = G.GAME.stake,
      ["balatro.run.resumed"] = args and args.savetext ~= nil or false,
      ["balatro.lua.memory.live"] = math.floor(collectgarbage("count") * 1024),
    })
  end)
  return ret
end

local update_game_over = Game.update_game_over
function Game:update_game_over(dt)
  safe(end_run, "lost") -- runs every frame in GAME_OVER; end_run no-ops after the first
  return update_game_over(self, dt)
end

-- Back to the main menu mid-run (pause menu, or a bot): the run ends there from the player's side.
local main_menu = Game.main_menu
function Game:main_menu(change_context)
  safe(end_run, "abandoned")
  return main_menu(self, change_context)
end

local win = win_game
function win_game()
  safe(function() if run then run.attrs["balatro.run.won"] = true end end)
  return win()
end

local select_blind = G.FUNCS.select_blind
G.FUNCS.select_blind = function(e)
  safe(function()
    end_blind(false)
    perf_reset()
    blind = otel.start("balatro.blind", {
      ["balatro.blind.name"] = e.config.ref_table.name,
      ["balatro.ante"] = G.GAME.round_resets.ante,
    }, run)
  end)
  return select_blind(e)
end

local orig_end_round = end_round
function end_round()
  safe(function()
    end_blind(big(G.GAME.chips) >= big(G.GAME.blind.chips))
    otel.flush()
  end)
  return orig_end_round()
end

local discard = G.FUNCS.discard_cards_from_highlighted
G.FUNCS.discard_cards_from_highlighted = function(e, hook)
  safe(function() otel.event("balatro.discard", { ["balatro.discard.card_count"] = #G.hand.highlighted }, blind) end)
  return discard(e, hook)
end

-- balatro.hand = scoring math plus the animation that plays it out; balatro.hand.scoring = the
-- synchronous math only. hand_chips/mult are globals the game updates while scoring.
local evaluate_play = G.FUNCS.evaluate_play
G.FUNCS.evaluate_play = function(e)
  local blind_score_before = G.GAME.chips
  safe(function()
    hand = otel.start("balatro.hand", { ["balatro.hand.card_count"] = #G.play.cards }, blind or run)
    scoring = otel.start("balatro.hand.scoring", nil, hand)
  end)
  local ret = evaluate_play(e)
  safe(function()
    otel.finish(scoring)
    scoring = nil
    local this_hand = hand
    -- The game adds math.floor(chips * mult) to the blind; x-mult jokers make the product fractional.
    -- Talisman big numbers are not plain numbers and stay unrounded (D() then leaves them out).
    local score = hand_chips * mult
    if type(score) == "number" then score = math.floor(score) end
    local result = {
      ["balatro.hand.type"] = G.GAME.last_hand_played,
      ["balatro.hand.chips"] = D(hand_chips),
      ["balatro.hand.mult"] = D(mult),
      ["balatro.hand.score"] = D(score),
    }
    otel.count("balatro.hands", 1, "{hand}", { ["balatro.hand.type"] = G.GAME.last_hand_played })
    otel.count("balatro.score", tonumber(score), "{chip}") -- Talisman big numbers are skipped
    -- Queued behind the scoring animations, so it fires once they have played out (and the blind's
    -- score has eased up): what the blind really gained, next to what the hand computed.
    G.E_MANAGER:add_event(Event({ func = function()
      safe(function()
        result["balatro.hand.blind_score_added"] = D(G.GAME.chips - blind_score_before)
        otel.finish(this_hand, result)
        if hand == this_hand then hand = nil end
      end)
      return true
    end }))
  end)
  return ret
end

-- Every card/joker evaluation during scoring; kept only if it produced an effect or was slow.
local orig_eval_card = eval_card
function eval_card(card, context)
  if not scoring then return orig_eval_card(card, context) end
  local t0 = otel.now()
  local ret, post = orig_eval_card(card, context)
  local t1 = otel.now()
  safe(function()
    if next(ret or {}) or next(post or {}) or t1 - t0 > SLOW_EVAL then
      local center = card.config and card.config.center
      otel.finish(otel.start("balatro.card.evaluate", effect_attrs(ret, {
        ["balatro.card.name"] = card_name(card),
        ["balatro.card.key"] = center and center.key,
        ["balatro.card.area"] = card.area == G.jokers and "jokers" or card.area == G.play and "play"
          or card.area == G.hand and "hand" or "other",
        ["balatro.card.evaluation.context"] = context_flags(context or {}),
      }), scoring, t0), nil, nil, t1)
    end
  end)
  return ret, post
end

-- The single place chips/mult/dollars change: a timeline of the score as it builds up.
local calculate_individual_effect = SMODS.calculate_individual_effect
SMODS.calculate_individual_effect = function(effect, scored_card, key, amount, from_edition)
  local ret = calculate_individual_effect(effect, scored_card, key, amount, from_edition)
  safe(function()
    if scoring and type(amount) == "number" then
      otel.event("balatro.effect", {
        ["balatro.effect.key"] = key,
        ["balatro.effect.amount"] = D(amount),
        ["balatro.effect.source"] = card_name(effect.card or scored_card),
        ["balatro.score.chips"] = D(hand_chips),
        ["balatro.score.mult"] = D(mult),
      }, scoring)
    end
  end)
  return ret
end

-- Shop: cash out opens it, "Next Round" (toggle_shop) closes it.
local cash_out = G.FUNCS.cash_out
G.FUNCS.cash_out = function(e)
  safe(function()
    end_shop()
    shop = otel.start("balatro.shop", { ["balatro.ante"] = G.GAME.round_resets.ante }, run)
  end)
  return cash_out(e)
end

local toggle_shop = G.FUNCS.toggle_shop
G.FUNCS.toggle_shop = function(e)
  safe(end_shop)
  return toggle_shop(e)
end

-- action is buy/sell/use/redeem: event balatro.card.<action> plus the balatro.card.actions counter.
local function card_event(action, card, extra)
  local a = extra or {}
  a["balatro.card.name"] = card_name(card)
  a["balatro.card.set"] = card.ability and card.ability.set
  a["balatro.card.key"] = card.config and card.config.center and card.config.center.key
  a["balatro.dollars"] = G.GAME.dollars
  otel.event("balatro.card." .. action, a, innermost())
  otel.count("balatro.card.actions", 1, "{action}", { ["balatro.card.action"] = action, ["balatro.card.set"] = a["balatro.card.set"] })
end

local buy_from_shop = G.FUNCS.buy_from_shop
G.FUNCS.buy_from_shop = function(e)
  local card = e.config.ref_table
  local cost = card and card.cost
  local ret = buy_from_shop(e)
  safe(function()
    -- returns false when there is no room for the card
    if ret ~= false then
      card_event("buy", card, { ["balatro.card.cost"] = cost, ["balatro.shop.buy_and_use"] = e.config.id == "buy_and_use" })
    end
  end)
  return ret
end

local reroll_shop = G.FUNCS.reroll_shop
G.FUNCS.reroll_shop = function(e)
  safe(function()
    otel.event("balatro.shop.reroll", {
      ["balatro.shop.reroll_cost"] = G.GAME.current_round.reroll_cost,
      ["balatro.dollars"] = G.GAME.dollars,
    }, shop)
  end)
  return reroll_shop(e)
end

-- Pack picks and consumables used from hand both go through use_card; with a pack open the event links to it.
local use_card = G.FUNCS.use_card
G.FUNCS.use_card = function(e, mute, nosave)
  safe(card_event, "use", e.config.ref_table)
  return use_card(e, mute, nosave)
end

local sell_card = Card.sell_card
function Card:sell_card()
  safe(card_event, "sell", self, { ["balatro.card.sell_value"] = self.sell_cost })
  return sell_card(self)
end

local redeem = Card.redeem
function Card:redeem()
  safe(card_event, "redeem", self)
  return redeem(self)
end

-- Booster pack: opening it starts a span, end_consumeable (pick done or skipped) ends it.
local open = Card.open
function Card:open()
  safe(function()
    end_pack()
    pack = otel.start("balatro.booster_pack", {
      ["balatro.card.name"] = card_name(self),
      ["balatro.card.key"] = self.config.center.key,
      ["balatro.booster_pack.skipped"] = false,
    }, shop or run)
  end)
  return open(self)
end

local skip_booster = G.FUNCS.skip_booster
G.FUNCS.skip_booster = function(e)
  safe(function() if pack then pack.attrs["balatro.booster_pack.skipped"] = true end end)
  return skip_booster(e)
end

local end_consumeable = G.FUNCS.end_consumeable
G.FUNCS.end_consumeable = function(e, delayfac)
  safe(end_pack)
  return end_consumeable(e, delayfac)
end

local skip_blind = G.FUNCS.skip_blind
G.FUNCS.skip_blind = function(e)
  safe(function()
    otel.event("balatro.blind.skip", {
      ["balatro.blind.slot"] = G.GAME.blind_on_deck,
      ["balatro.ante"] = G.GAME.round_resets.ante,
    }, run)
  end)
  return skip_blind(e)
end

-- Steamodded's logger (used by every mod) becomes OTLP logs: one scope per logger name.
for _, level in ipairs({ "Info", "Warn", "Error", "Fatal" }) do
  local name = "send" .. level .. "Message"
  local orig = _G[name]
  if orig then
    _G[name] = function(message, logger)
      safe(otel.log, level:upper(), message, nil, innermost(), logger or "DefaultLogger")
      return orig(message, logger)
    end
  end
end

local function export_metrics()
  otel.gauge("balatro.frame.rate", love.timer.getFPS(), "{frame}/s")
  otel.gauge("balatro.lua.memory.used", collectgarbage("count") * 1024, "By")
  otel.gauge("balatro.event_queue.length", #G.E_MANAGER.queues.base, "{event}")
  otel.gauge("balatro.render.draw_calls", frame_stats.drawcalls, "{call}")
  otel.gauge("balatro.render.canvas_switches", frame_stats.canvasswitches, "{switch}")
  otel.gauge("balatro.render.shader_switches", frame_stats.shaderswitches, "{switch}")
  otel.gauge("balatro.render.texture_memory.used", frame_stats.texturememory, "By")
  if run then
    otel.gauge("balatro.dollars", G.GAME.dollars, "{dollar}")
    otel.gauge("balatro.ante", G.GAME.round_resets.ante, "{ante}")
  end
  otel.flush()
end

-- Frame timing. `frame` is the wall time between two updates, i.e. the previous frame (its update,
-- draw, present and vsync wait), paired with the update/draw CPU time measured in that frame. It is
-- measured here rather than taken from update's dt, which mods may fix to a constant (BalatroBot
-- does). Draw time is CPU-side command submission; GPU work and the vsync wait land in "other".
local last_update, last_draw, last_export, last_frame_start = 0, 0, otel.now(), nil

local function on_frame(frame)
  otel.histogram("balatro.frame.duration", frame, "s")
  otel.histogram("balatro.frame.update.duration", last_update, "s")
  otel.histogram("balatro.frame.draw.duration", last_draw, "s")

  perf.frames = perf.frames + 1
  perf.dt_sum = perf.dt_sum + frame
  perf.dt_max = math.max(perf.dt_max, frame)
  local mem = collectgarbage("count")
  perf.mem_max = math.max(perf.mem_max, mem)
  local queue = G.E_MANAGER and #G.E_MANAGER.queues.base or 0
  perf.queue_max = math.max(perf.queue_max, queue)

  if frame > JANK_THRESHOLD then
    perf.slow = perf.slow + 1
    local state = state_name()
    otel.count("balatro.frame.janks", 1, "{frame}", { ["balatro.game.state"] = state })
    otel.event("app.jank", {
      ["app.jank.frame_count"] = 1,
      ["app.jank.threshold"] = D(JANK_THRESHOLD),
      ["app.jank.period"] = D(frame),
      ["balatro.game.state"] = state,
      ["balatro.frame.update.duration"] = D(last_update),
      ["balatro.frame.draw.duration"] = D(last_draw),
      ["balatro.frame.other.duration"] = D(math.max(frame - last_update - last_draw, 0)),
      ["balatro.render.draw_calls"] = frame_stats.drawcalls,
      ["balatro.event_queue.length"] = queue,
      ["balatro.lua.memory.used"] = math.floor(mem * 1024),
    }, innermost(), "WARN")
  end

  if otel.now() - last_export >= EXPORT_INTERVAL then
    last_export = otel.now()
    export_metrics()
  end
end

local update = Game.update
function Game:update(dt)
  local t0 = love.timer.getTime()
  if last_frame_start then safe(on_frame, t0 - last_frame_start) end
  last_frame_start = t0
  local ret = update(self, dt)
  last_update = love.timer.getTime() - t0
  -- here, not in draw: headless runs (BalatroBot --headless) never draw
  perf.update_sum, perf.update_max = perf.update_sum + last_update, math.max(perf.update_max, last_update)
  return ret
end

local draw = Game.draw
function Game:draw()
  local t0 = love.timer.getTime()
  local ret = draw(self)
  last_draw = love.timer.getTime() - t0
  safe(function()
    love.graphics.getStats(frame_stats) -- refills the table instead of allocating one per frame
    perf.draw_sum, perf.draw_max = perf.draw_sum + last_draw, math.max(perf.draw_max, last_draw)
    perf.drawcalls_max = math.max(perf.drawcalls_max, frame_stats.drawcalls)
    perf.canvas_max = math.max(perf.canvas_max, frame_stats.canvasswitches)
    perf.shader_max = math.max(perf.shader_max, frame_stats.shaderswitches)
    perf.texmem_max = math.max(perf.texmem_max, frame_stats.texturememory)
  end)
  return ret
end

-- Crash: emit app.crash, fail every open span (error.type = lua_error) so the tree is complete, and
-- flush before Steamodded's crash screen takes over. Runs as the xpcall handler, so the stack is intact.
local errorhandler = love.errorhandler
function love.errorhandler(msg)
  local trace = debug.traceback(tostring(msg), 2)
  pcall(function()
    otel.event("app.crash", {
      ["app.crash.id"] = otel.uuid(),
      ["exception.message"] = tostring(msg),
      ["exception.stacktrace"] = trace,
      ["balatro.game.state"] = state_name(),
      ["balatro.lua.memory.used"] = math.floor(collectgarbage("count") * 1024),
    }, innermost(), "FATAL")
    otel.count("balatro.crashes", 1, "{crash}")
    for _, span in pairs({ scoring, hand, pack, shop, blind, run }) do
      otel.finish(span, { ["error.type"] = "lua_error" }, msg)
    end
    scoring, hand, pack, shop, blind, run = nil, nil, nil, nil, nil, nil
    otel.flush()
  end)
  return errorhandler(msg)
end
