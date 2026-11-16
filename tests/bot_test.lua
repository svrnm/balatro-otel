-- BalatroBot middleware lifecycle tests using the real OTLP encoder and controlled callbacks.
local smods = os.getenv("SMODS_DIR") or (os.getenv("HOME") .. "/Library/Application Support/Balatro/Mods/smods")
package.path = smods .. "/libs/json/?.lua;mod/otel-trace/?.lua;" .. package.path
local game = require "otel"
local server = assert(loadfile("mod/otel-trace/otel.lua"))()
server.flush = function() end -- retain real encoded records for assertions and Weaver fixtures
local bot = require "bot"
local function attrs(list)
  local out = {}
  for _, a in ipairs(list or {}) do
    local v = a.value
    out[a.key] = v.stringValue or v.doubleValue or (v.intValue and tonumber(v.intValue)) or v.boolValue
  end
  return out
end
local tid, sid = string.rep("a", 32), string.rep("b", 16)
local function header(value) return "POST / HTTP/1.1\r\nTraceparent: " .. value .. "\r\n\r\n{}" end
local valid = "00-" .. tid .. "-" .. sid .. "-01"
assert(bot.extract(header(valid)).traceId == tid)
for _, value in ipairs({ valid:upper(), valid .. "-extra", "ff" .. valid:sub(3),
  "00-" .. string.rep("0",32) .. "-" .. sid .. "-01", "00-" .. tid .. "-" .. string.rep("0",16) .. "-01", "garbage" }) do
  assert(bot.extract(header(value)) == nil, value)
end
assert(bot.extract(header(valid):gsub("\r\n\r\n", "\r\ntraceparent: " .. valid .. "\r\n\r\n")) == nil)
assert(bot.extract(header("01" .. valid:sub(3) .. "-future")))
local clock = 1000
server.now = function() return clock end
game.common["session.id"] = game.uuid()
local root = game.start("balatro.run", { ["balatro.run.seed"] = "BOTTEST" })
local callbacks, observed = {}, {}
SMODS = { Mods = { balatrobot = { version = "1.5.2" } } }
BB_SETTINGS = { host = "127.0.0.1", port = 12346 }
BB_ERROR_CODES = { BAD_REQUEST = -32600, INTERNAL_ERROR = -32603 }
BB_SERVER = {
  send_response = function(response)
    observed[#observed + 1] = response
    BB_SERVER.client_socket = nil
    return true, nil, "sent"
  end,
  close = function() BB_SERVER.client_socket = nil; return "closed" end,
}
BB_DISPATCHER = { Server = BB_SERVER, endpoints = {
  health = { execute = function(_, send) return send({ status = "ok" }) end },
  play = { execute = function(_, send) callbacks[#callbacks + 1] = send; return "pending" end },
} }
function BB_DISPATCHER.dispatch(request)
  local endpoint = BB_DISPATCHER.endpoints[request.method]
  if not endpoint then return BB_SERVER.send_response({ message = "unknown", name = "BAD_REQUEST" }) end
  return endpoint.execute(request.params, function(...) return BB_SERVER.send_response(...) end)
end
local middleware = bot.new(game, server, function() return root end)
middleware.update(); middleware.update()
local function request(method, traceparent)
  BB_SERVER.client_socket = {}
  BB_SERVER.client_state = { buffer = traceparent and header(traceparent) or "POST / HTTP/1.1\r\n\r\n{}" }
  return BB_DISPATCHER.dispatch({ method = method, id = 1, params = {} })
end
local a, b, c = request("health", valid)
assert(a == true and b == nil and c == "sent", "all original return values preserved")
local span = server.buffer[1]
assert(span.kind == 2 and span.traceId == tid and span.parentSpanId == sid)
assert(span.links[1].spanId == root.spanId and span.links[1].traceId == root.traceId)
assert(middleware.pending == nil and game.link_context == nil)
assert(attrs(span.attributes)["rpc.method"] == "health")
assert(request("play", valid) == "pending")
local pending = middleware.pending
assert(#server.buffer == 1 and game.link_context == pending.span, "async span stays open")
local hand = game.start("balatro.hand", {}, root)
assert(hand.parentSpanId == root.spanId and hand.traceId == root.traceId, "game hierarchy preserved")
assert(hand.links[1].traceId == tid and hand.links[1].spanId == pending.span.spanId, "command linked to game span")
game.finish(hand)
clock = clock + 3
callbacks[1]({ status = "ok" })
assert(#server.buffer == 2 and middleware.pending == nil and game.link_context == nil)
assert(tonumber(server.buffer[2].endTimeUnixNano) - tonumber(server.buffer[2].startTimeUnixNano) == 3e9)
local count = 0
for _, p in pairs(server.metrics["rpc.server.call.duration"].points) do count = count + p.count end
assert(count == 2, "callbacks and repeated polls do not double count")

request("play", valid)
callbacks[2]({ message = "rejected", name = "BAD_REQUEST" })
span = server.buffer[#server.buffer]
assert(span.status.code == 2 and attrs(span.attributes)["rpc.response.status_code"] == "-32600")
request("custom_method", valid)
span = server.buffer[#server.buffer]
local a4 = attrs(span.attributes)
assert(span.name == "jsonrpc" and a4["rpc.method"] == "_OTHER" and a4["rpc.method_original"] == "custom_method")

request("play", valid)
local abandoned = middleware.pending
BB_SERVER.client_socket = nil
middleware.update()
assert(abandoned.done and game.link_context == nil)
assert(attrs(server.buffer[#server.buffer].attributes)["error.type"] == "client_disconnected")
request("play", valid)
local next_request = middleware.pending
local previous_count = #server.buffer
callbacks[3]({ status = "late" })
assert(middleware.pending == next_request and #server.buffer == previous_count, "old callback cannot finish new request")
middleware.update() -- the fake send closed the new socket, just as an old upstream callback could
assert(next_request.done)
request("play", valid)
clock = clock + 121
middleware.update()
assert(attrs(server.buffer[#server.buffer].attributes)["error.type"] == "timeout")
local n = #server.buffer
callbacks[#callbacks]({ status = "late" })
assert(#server.buffer == n, "timed-out request completes only once")
n = #server.buffer
request("health", valid:sub(1,-3) .. "00")
assert(#server.buffer == n and game.link_context == nil, "unsampled remote request has no exported request span")
request("health", "malformed")
assert(server.buffer[#server.buffer].traceId ~= tid, "invalid propagation starts a new trace")
request("play", valid)
assert(BB_SERVER.close() == "closed")
assert(attrs(server.buffer[#server.buffer].attributes)["error.type"] == "shutdown")
assert(middleware.pending == nil and game.link_context == nil)
-- Telemetry observation failure must not prevent a command or its callback from executing.
local histogram = server.histogram
server.histogram = function() error("deliberate observer failure") end
local before = #observed
request("health", valid)
assert(#observed == before + 1 and middleware.pending == nil and game.link_context == nil)
server.histogram = histogram
-- Validate the RPC-specific bucket range rather than frame-duration buckets.
for _, p in pairs(server.metrics["rpc.server.call.duration"].points) do
  assert(p.bounds[#p.bounds] == 120)
end
game.finish(root, { ["balatro.run.outcome"] = "abandoned" })
if arg[1] then
  local function write(name, body)
    local f = assert(io.open(arg[1] .. "/" .. name .. ".json", "w")); f:write(body); f:close()
  end
  write("bot-server-traces", server.encode(server.buffer))
  write("bot-server-logs", server.encode_logs(server.logs))
  write("bot-server-metrics", server.encode_metrics())
  write("bot-game-traces", game.encode(game.buffer))
end
io.stderr:write("ok: RPC propagation, async lifecycle, links, sampling, errors, cancellation, stale callbacks, and observer isolation\n")
