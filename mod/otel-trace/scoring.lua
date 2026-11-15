-- Scoring evidence, not counterfactual credit. Definitions live in telemetry/registry.
-- All observations are guarded; original game calls and their return values are preserved.
local M = {}
local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end
local function nonempty(t) return type(t) == "table" and next(t) ~= nil end

function M.install(otel, current_scoring)
  local ids, next_id = setmetatable({}, { __mode = "k" }), 0
  local active_span, sequence, effect_parent, component = nil, 0, nil, "unknown"
  local D = otel.double

  local function observe(f, ...)
    local ok, result = pcall(f, ...)
    if ok then return result end
    pcall(otel.log, "WARN", "otel hook failed: " .. tostring(result), nil, current_scoring())
  end

  local function active()
    local span = current_scoring()
    if span ~= active_span then
      active_span, sequence, effect_parent, component = span, 0, nil, "unknown"
    end
    return span
  end

  local function id(card)
    if type(card) ~= "table" then return end
    if not ids[card] then next_id = next_id + 1; ids[card] = "card-" .. next_id end
    return ids[card]
  end

  local function name(card)
    if not card then return "?" end
    if card.ability and card.ability.set == "Joker" then return card.ability.name or "?" end
    if card.base and card.base.value then return card.base.value .. " of " .. tostring(card.base.suit) end
    return card.ability and card.ability.name or "?"
  end

  local function key(card) return card and card.config and card.config.center and card.config.center.key end

  local function area(card)
    if card.area == G.jokers then return "jokers" end
    if card.area == G.play then return "play" end
    if card.area == G.hand then return "hand" end
    return "other"
  end

  local function snapshot(card, context)
    context = context or {}
    local flags = {}
    for k, v in pairs(context) do if v == true then flags[#flags + 1] = k end end
    table.sort(flags)
    local edition = card.edition and card.edition.key
    if not edition then
      -- Legacy vanilla editions have boolean flags instead of a key. Do not inspect arbitrary
      -- custom tables or call property getters: those can themselves run game calculations.
      for _, k in ipairs({ "foil", "holo", "polychrome", "negative" }) do
        if card.edition and card.edition[k] then edition = "e_" .. k; break end
      end
    end
    local set = card.ability and card.ability.set
    return {
      ["balatro.card.instance.id"] = id(card),
      ["balatro.card.name"] = name(card),
      ["balatro.card.key"] = key(card),
      ["balatro.card.set"] = set,
      ["balatro.card.area"] = area(card),
      ["balatro.card.rank"] = card.base and card.base.value and tostring(card.base.value),
      ["balatro.card.suit"] = card.base and card.base.suit,
      ["balatro.card.enhancement"] = set == "Enhanced" and key(card) or nil,
      ["balatro.card.edition"] = edition,
      ["balatro.card.seal"] = card.seal,
      ["balatro.card.debuffed"] = not not card.debuff,
      ["balatro.card.evaluation.context"] = table.concat(flags, ","),
      ["balatro.card.evaluation.retrigger"] = not not context.retrigger_joker,
      ["balatro.card.evaluation.copy"] = not not (context.blueprint or context.blueprint_card),
      ["balatro.card.evaluation.copy_source.id"] = id(context.blueprint_card),
      ["balatro.card.evaluation.retrigger_source.id"] = id(context.retrigger_joker),
    }
  end

  local function returned_attributes(ret, out, prefix)
    for source, effect in pairs(type(ret) == "table" and ret or {}) do
      if type(source) == "string" and type(effect) == "table" then
        for k, v in pairs(effect) do
          if type(k) == "string" and type(v) == "number" then out[prefix .. source .. "." .. k] = D(v) end
        end
      end
    end
  end

  local eval = eval_card
  function eval_card(card, context, ...)
    local span = active()
    if not span then return eval(card, context, ...) end
    local a = observe(snapshot, card, context)
    local t0 = otel.now()
    local results = pack(eval(card, context, ...))
    local t1 = otel.now()
    observe(function()
      otel.count("balatro.card.evaluations", 1, "{evaluation}", {
        ["balatro.card.area"] = a and a["balatro.card.area"] or "other",
      })
      if not a then return end
      local primary, post = nonempty(results[1]), nonempty(results[2])
      if primary or post or t1 - t0 > 0.001 then
        a["balatro.card.evaluation.has_effects"] = primary
        a["balatro.card.evaluation.has_post_effects"] = post
        returned_attributes(results[1], a, "balatro.card.effect.")
        -- Steamodded post effects are an ordered list of evaluation result tables.
        if type(results[2]) == "table" and results[2][1] then
          for i, ret in ipairs(results[2]) do
            returned_attributes(ret, a, "balatro.card.post_effect." .. i .. ".")
          end
        else
          returned_attributes(results[2], a, "balatro.card.post_effect.")
        end
        otel.finish(otel.start("balatro.card.evaluate", a, span, t0), nil, nil, t1)
      end
    end)
    return unpack(results, 1, results.n)
  end

  local calculate_joker = Card.calculate_joker
  function Card:calculate_joker(context, ...)
    local span = active()
    if not span then return calculate_joker(self, context, ...) end
    local a = observe(snapshot, self, context)
    local results = pack(calculate_joker(self, context, ...))
    observe(function()
      -- Steamodded consumes this separate result in eval_card. Do not infer it from effects.
      if results[2] == true and a then
        a["balatro.card.trigger.reported"] = true
        otel.event("balatro.card.trigger", a, span)
        otel.count("balatro.card.triggers", 1, "{trigger}", {
          ["balatro.card.evaluation.retrigger"] = a["balatro.card.evaluation.retrigger"],
        })
      end
    end)
    return unpack(results, 1, results.n)
  end

  -- Blueprint/Brainstorm call calculate_joker directly, bypassing eval_card. Observe their
  -- explicit helper boundary so effect-only copies remain visible without inventing triggers.
  local blueprint = SMODS.blueprint_effect
  if blueprint then
    SMODS.blueprint_effect = function(copier, copied, context, ...)
      local span = active()
      if not span or not copier or not copied then return blueprint(copier, copied, context, ...) end
      local a = observe(snapshot, copied, context)
      local copier_id = observe(id, copier)
      local results = pack(blueprint(copier, copied, context, ...))
      observe(function()
        if a and nonempty(results[1]) then
          a["balatro.card.evaluation.copy"] = true
          a["balatro.card.evaluation.copy_source.id"] = copier_id
          a["balatro.card.evaluation.has_effects"] = true
          otel.event("balatro.card.copy", a, span)
        end
      end)
      return unpack(results, 1, results.n)
    end
  end

  -- This path supplies the component explicitly. Dynamic keys and non-card sources stay unknown.
  local table_key = SMODS.calculate_effect_table_key
  if table_key then
    SMODS.calculate_effect_table_key = function(effect_table, k, card, ret, ...)
      if not active() then return table_key(effect_table, k, card, ret, ...) end
      local previous = component
      local components = { jokers = "joker", playing_card = "playing_card", enhancement = "enhancement",
        edition = "edition", seals = "seal" }
      component = components[k] or "unknown"
      local results = pack(table_key(effect_table, k, card, ret, ...))
      component = previous
      return unpack(results, 1, results.n)
    end
  end

  local individual = SMODS.calculate_individual_effect
  SMODS.calculate_individual_effect = function(effect, target, k, amount, from_edition, ...)
    local span = active()
    if not span then return individual(effect, target, k, amount, from_edition, ...) end
    local parent, this_component = effect_parent, from_edition and "edition" or component
    sequence = sequence + 1
    local seq = sequence
    local a = observe(function()
      local source = effect and effect.card
      return {
        ["balatro.effect.key"] = k,
        ["balatro.effect.amount"] = D(amount),
        ["balatro.effect.source"] = name(source or target), -- legacy display fallback
        ["balatro.effect.attribution"] = source and "explicit" or target and "target_fallback" or "unknown",
        ["balatro.effect.source_card.instance.id"] = id(source),
        ["balatro.effect.source_card.key"] = key(source),
        ["balatro.effect.target.instance.id"] = id(target),
        ["balatro.effect.target.key"] = key(target),
        ["balatro.effect.target.name"] = target and name(target),
        ["balatro.effect.sequence"] = seq,
        ["balatro.effect.parent_sequence"] = parent,
        ["balatro.effect.component"] = this_component,
        ["balatro.effect.from_edition"] = not not from_edition,
        ["balatro.score.before.chips"] = D(hand_chips),
        ["balatro.score.before.mult"] = D(mult),
      }
    end)
    effect_parent = seq
    local results = pack(individual(effect, target, k, amount, from_edition, ...))
    effect_parent = parent
    observe(function()
      local ret = results[1]
      local outcome = "unknown"
      if ret == true or type(ret) == "string" or type(ret) == "table" then outcome = "handled"
      elseif ret == false then outcome = "unhandled" end
      otel.count("balatro.effects", 1, "{effect}", {
        ["balatro.effect.component"] = this_component, ["balatro.effect.outcome"] = outcome,
      })
      if a then
        a["balatro.effect.outcome"] = outcome
        a["balatro.score.chips"], a["balatro.score.mult"] = D(hand_chips), D(mult)
        otel.event("balatro.effect", a, span)
      end
    end)
    return unpack(results, 1, results.n)
  end
end

return M
