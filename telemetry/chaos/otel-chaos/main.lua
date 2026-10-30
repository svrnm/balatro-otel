-- Test-only fault injection, to see how otel-trace reports performance problems, bugs and crashes.
-- Never install it for real play. OTEL_CHAOS is a comma-separated list of scenarios:
--   jank         0.4 s stall in cash-out                       -> app.jank, balatro.frame.janks
--   slow_joker   30 ms in every joker's main scoring           -> slow balatro.card.evaluate spans
--   queue_flood  200 extra queued events at blind start        -> balatro.event_queue.max_length
--   leak         4 KB retained per frame                       -> balatro.lua.memory.used grows
--   score_bug    +7 chips silently added after each hand       -> blind score != sum of hands
--   mod_error    a "mod" logging errors/warnings via Steamodded -> ERROR/WARN logs, scope ChaosMod
--   crash        Lua error in joker scoring on the 3rd hand    -> app.crash, failed spans
--   draw_heavy   20 extra rectangles drawn per card            -> draw calls/time (render mode only)
--   render       no fault; only switches the container to render mode (baseline for draw_heavy)
-- Faults sit inside game functions so they are measured where a real problem would be.
local on = {}
for name in (os.getenv("OTEL_CHAOS") or ""):gmatch("[^,%s]+") do on[name] = true end
print("[chaos] scenarios: " .. (os.getenv("OTEL_CHAOS") or "none"))

local function busy(seconds)
  local stop = love.timer.getTime() + seconds
  while love.timer.getTime() < stop do end
end

local hands_played = 0

local calculate_joker = Card.calculate_joker
function Card:calculate_joker(context)
  if context.joker_main then
    if on.slow_joker then busy(0.03) end
    if on.crash and hands_played >= 3 then
      local missing = nil
      return missing.ability.extra -- a typical modding bug: indexing a nil card
    end
  end
  return calculate_joker(self, context)
end

local evaluate_play = G.FUNCS.evaluate_play
G.FUNCS.evaluate_play = function(e)
  hands_played = hands_played + 1
  local ret = evaluate_play(e)
  if on.score_bug then
    G.E_MANAGER:add_event(Event({ func = function()
      G.GAME.chips = G.GAME.chips + 7
      return true
    end }))
  end
  return ret
end

local cash_out = G.FUNCS.cash_out
G.FUNCS.cash_out = function(e)
  if on.jank then busy(0.4) end
  return cash_out(e)
end

local select_blind = G.FUNCS.select_blind
G.FUNCS.select_blind = function(e)
  if on.mod_error then
    sendErrorMessage("Failed to load atlas 'chaos_jokers': file not found", "ChaosMod")
    sendWarnMessage("Falling back to default sprite for j_chaos_joker", "ChaosMod")
  end
  local ret = select_blind(e)
  if on.queue_flood then
    for _ = 1, 200 do
      G.E_MANAGER:add_event(Event({ trigger = "after", delay = 0.01, func = function() return true end }))
    end
  end
  return ret
end

local leaked = {}
local update = Game.update
function Game:update(dt)
  if on.leak then leaked[#leaked + 1] = string.rep("x", 4096) .. #leaked end
  return update(self, dt)
end

local card_draw = Card.draw
function Card:draw(layer)
  card_draw(self, layer)
  if on.draw_heavy and (layer == nil or layer == "card") then
    local mode = love.graphics.getBlendMode()
    for i = 1, 20 do
      -- LÖVE batches consecutive shapes; switching blend mode forces a draw call per rectangle
      love.graphics.setBlendMode(i % 2 == 0 and "add" or "alpha")
      love.graphics.rectangle("fill", self.T.x + i * 0.01, self.T.y, 0.01, 0.01)
    end
    love.graphics.setBlendMode(mode)
  end
end
