-- Optional BalatroBot middleware. No upstream server files are changed.
-- The server is single-client; a command remains active across frames until its response.
local M = {}
local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end
local METHODS = {}
for method in ("health gamestate save load screenshot set add menu start skip select play discard cash_out " ..
  "next_round reroll buy pack rearrange sell use rpc.discover"):gmatch("%S+") do METHODS[method] = true end
local BOUNDS = { 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10, 30, 60, 120 }

-- W3C traceparent. Reject invalid IDs/versions/duplicates rather than changing game behavior.
function M.extract(buffer)
  local headers = (buffer or ""):sub(1, 8192):match("^(.-)\r\n\r\n")
  if not headers then return end
  local value
  for line in headers:gmatch("[^\r\n]+") do
    local name, v = line:match("^([^:]+):%s*(.-)%s*$")
    if name and name:lower() == "traceparent" then
      if value then return end
      value = v
    end
  end
  if not value then return end
  local version, tid, sid, flags = value:match("^(%x%x)%-(%x+)%-(%x+)%-(%x%x)")
  if not version or value ~= value:lower() or version == "ff" or #tid ~= 32 or #sid ~= 16 then return end
  if tid == string.rep("0", 32) or sid == string.rep("0", 16) then return end
  if version == "00" and #value ~= 55 then return end
  if #value > 55 and value:sub(56, 56) ~= "-" then return end
  return { traceId = tid, spanId = sid, flags = tonumber(flags, 16) }
end

function M.new(game, otel, game_span)
  local self = { pending = nil, installed = false }
  local responding
  otel.resource["service.name"] = "balatrobot"
  otel.resource["service.instance.id"] = otel.uuid()
  otel.common["session.id"] = game.common["session.id"]
  local function monotonic()
    return love and love.timer and love.timer.getTime() or otel.now()
  end

  local function observe(f, ...)
    local ok, result = pcall(f, ...)
    if ok then return result end
    pcall(game.log, "WARN", "otel hook failed: " .. tostring(result), nil, game_span())
  end

  local function finish(req, response, transport_error)
    if not req or req.done then return end
    req.done = true
    if self.pending == req then self.pending = nil end
    if game.link_context == req.span then game.link_context = nil end
    local err = transport_error or (response and response.message and "jsonrpc_error")
    local a = { ["rpc.system.name"] = "jsonrpc", ["rpc.method"] = req.method }
    if err then a["error.type"] = err end
    local code
    if response and response.message then
      local codes = BB_ERROR_CODES or {}
      code = codes[response.name] or codes.INTERNAL_ERROR
      if code then
        local known = { [-32700] = true, [-32600] = true, [-32601] = true, [-32602] = true, [-32603] = true }
        a["rpc.response.status_code"] = known[code] and tostring(code) or "_OTHER"
      end
    end
    otel.histogram("rpc.server.call.duration", math.max(0, monotonic() - req.tick), "s", a, BOUNDS)
    if req.span then
      local result = {}
      if code then result["rpc.response.status_code"] = tostring(code) end
      if err then
        result["error.type"] = err
        otel.event("balatro.bot.request.failed", { ["rpc.method"] = req.method, ["error.type"] = err }, req.span, "WARN")
      end
      otel.finish(req.span, result, err and "Bot request failed" or nil)
    end
    otel.endpoint = game.endpoint
    otel.flush()
  end

  function self.abort(reason) observe(finish, self.pending, nil, reason or "shutdown") end

  function self.update()
    if not self.installed and BB_SERVER and BB_DISPATCHER and BB_DISPATCHER.Server then
      local server, dispatcher = BB_SERVER, BB_DISPATCHER
      self.installed = true
      local mod = SMODS and SMODS.Mods and SMODS.Mods.balatrobot
      if mod and mod.version then otel.resource["service.version"] = mod.version end
      local dispatch, send, close = dispatcher.dispatch, server.send_response, server.close
      dispatcher.dispatch = function(request, ...)
        observe(function()
          finish(self.pending, nil, "superseded")
          local method = METHODS[request.method] and request.method or "_OTHER"
          local state = server.client_state
          local parent = M.extract(state and state.buffer)
          local seed = game.common["balatro.run.seed"]
          if request.method == "start" and type(request.params) == "table" and type(request.params.seed) == "string" then
            seed = request.params.seed
          end
          otel.common["balatro.run.seed"] = seed
          local a = { ["rpc.system.name"] = "jsonrpc", ["rpc.method"] = method,
            ["jsonrpc.protocol.version"] = "2.0", ["jsonrpc.request.id"] = tostring(request.id),
            ["balatro.bot.role"] = "server", ["server.address"] = BB_SETTINGS and BB_SETTINGS.host or "127.0.0.1",
            ["server.port"] = BB_SETTINGS and BB_SETTINGS.port or 12346 }
          if method == "_OTHER" and type(request.method) == "string" then a["rpc.method_original"] = request.method end
          local req = { method = method, socket = server.client_socket, started = otel.now(), tick = monotonic() }
          -- Honor the remote sampled flag for request spans. Metrics are always recorded.
          if not parent or parent.flags % 2 == 1 then
            req.span = otel.start(method == "_OTHER" and "jsonrpc" or method, a, parent, req.started)
            req.span.kind = 2 -- SERVER
            local related = game_span()
            if related then req.span.links = { { traceId = related.traceId, spanId = related.spanId } } end
          end
          self.pending = req
          game.link_context = req.span
        end)
        return dispatch(request, ...)
      end
      server.send_response = function(response, ...)
        local req = responding or self.pending
        local result = pack(send(response, ...))
        observe(finish, req, response, result[1] == false and "send_error" or nil)
        return unpack(result, 1, result.n)
      end
      -- Bind endpoint callbacks to the originating request, even if an old callback fires after
      -- a disconnect and a new request. Such a callback must not finish the new request's span.
      for _, endpoint in pairs(dispatcher.endpoints or {}) do
        local execute = endpoint.execute
        endpoint.execute = function(params, callback, ...)
          local req = self.pending
          return execute(params, function(...)
            local previous = responding
            responding = req
            local result = pack(pcall(callback, ...))
            responding = previous
            if not result[1] then error(result[2], 0) end
            return unpack(result, 2, result.n)
          end, ...)
        end
      end
      server.close = function(...)
        self.abort("shutdown")
        return close(...)
      end
    end
    local req = self.pending
    if req then
      if BB_SERVER.client_socket ~= req.socket then self.abort("client_disconnected")
      elseif monotonic() - req.tick > 120 then self.abort("timeout") end
    end
  end
  return self
end

return M
