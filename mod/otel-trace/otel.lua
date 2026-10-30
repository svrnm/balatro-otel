-- Minimal OTLP/HTTP JSON exporter for traces, logs and metrics. No SDK: build the payload tables,
-- POST them to a collector from a background thread so the game never waits on the network.
-- Names follow telemetry/registry (checked with Weaver) and OTel semantic conventions v1.44.0.
local json = require "json"

local SDK_NAME, SDK_VERSION = "balatro-otel-trace", "0.2.0"

local M = {
  -- standard OTLP env var (base URL; /v1/traces etc. are appended)
  endpoint = (os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT") or "http://127.0.0.1:4318"):gsub("/$", ""),
  -- sent once per batch, applies to every span/log/metric
  resource = {
    ["service.name"] = "balatro",
    ["telemetry.sdk.name"] = SDK_NAME,
    ["telemetry.sdk.language"] = "lua",
    ["telemetry.sdk.version"] = SDK_VERSION,
  },
  common = {},  -- copied onto every span and log record created while set
  buffer = {},  -- finished spans
  logs = {},    -- scope name -> log records
  metrics = {}, -- name -> { kind, unit, points }
}

local has_socket, socket = pcall(require, "socket")

-- socket.gettime is sub-ms wall clock (ships with LÖVE); os.time is the 1s fallback outside the game
function M.now() return has_socket and socket.gettime() or os.time() end

local function ns(t) return string.format("%.0f", t * 1e9) end

local session_start = ns(M.now()) -- cumulative metrics count from here

-- The game reseeds math.random with the run seed, so IDs need their own generator or
-- two runs on the same seed would reuse trace IDs. math.random is the fallback outside LÖVE.
local rng = love and love.math.newRandomGenerator(os.time(), math.floor(M.now() % 1 * 1e6))
local function rand(lo, hi) return rng and rng:random(lo, hi) or math.random(lo, hi) end

function M.id(bytes)
  local t = {}
  for i = 1, bytes do t[i] = string.format("%02x", rand(0, 255)) end
  return table.concat(t)
end

-- Random (version 4) UUID, the recommended format for service.instance.id and session.id.
function M.uuid()
  local h = M.id(16)
  local variant = string.format("%x", 8 + rand(0, 3))
  return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-4" .. h:sub(14, 16) .. "-" .. variant .. h:sub(18, 20) .. "-" .. h:sub(21, 32)
end

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function attrs(tbl)
  local out = {}
  for k, v in pairs(tbl) do
    local value
    if type(v) == "boolean" then
      value = { boolValue = v }
    elseif type(v) == "table" and finite(v.double) then
      value = { doubleValue = v.double } -- from M.double
    elseif finite(v) and v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      value = { intValue = string.format("%d", v) } -- int64 is a string in OTLP JSON
    elseif finite(v) then
      value = { doubleValue = v }
    else
      -- Talisman big numbers, inf and nan end up here
      value = { stringValue = tostring(v) }
    end
    out[#out + 1] = { key = k, value = value }
  end
  return out
end

-- Whole numbers are sent as int; wrap values of double-typed attributes so they stay doubles
-- even when whole (e.g. 300 chips). Values that don't fit a double (inf, Talisman big numbers)
-- return nil, which leaves the attribute out rather than sending the wrong type.
function M.double(v)
  if finite(v) then return { double = v } end
end

local function with_common(attributes)
  attributes = attributes or {}
  for k, v in pairs(M.common) do
    if attributes[k] == nil then attributes[k] = v end
  end
  return attributes
end

-- Traces --------------------------------------------------------------------------------------

-- start_time/end_time (seconds, from M.now) let callers record spans after the fact.
function M.start(name, attributes, parent, start_time)
  return {
    traceId = parent and parent.traceId or M.id(16),
    spanId = M.id(8),
    parentSpanId = parent and parent.spanId,
    name = name,
    kind = 1, -- INTERNAL
    startTimeUnixNano = ns(start_time or M.now()),
    attrs = with_common(attributes),
  }
end

-- err marks the span as failed (OTLP status ERROR) with err as the message.
function M.finish(span, attributes, err, end_time)
  for k, v in pairs(attributes or {}) do span.attrs[k] = v end
  if err then span.status = { code = 2, message = tostring(err) } end
  span.endTimeUnixNano = ns(end_time or M.now())
  span.attributes = attrs(span.attrs)
  span.attrs = nil
  M.buffer[#M.buffer + 1] = span
end

-- Logs and events -----------------------------------------------------------------------------

local SEVERITY = { DEBUG = 5, INFO = 9, WARN = 13, ERROR = 17, FATAL = 21 }

-- span (optional) correlates the record with the trace that was active; scope is the emitting
-- component (e.g. the Steamodded logger name), as log bridges map logger names to scopes.
function M.log(severity, message, attributes, span, scope, event_name)
  scope = scope or SDK_NAME
  local t = ns(M.now())
  M.logs[scope] = M.logs[scope] or {}
  local records = M.logs[scope]
  records[#records + 1] = {
    timeUnixNano = t,
    observedTimeUnixNano = t,
    severityNumber = SEVERITY[severity],
    severityText = severity,
    body = message and { stringValue = tostring(message) },
    eventName = event_name,
    attributes = attrs(with_common(attributes)),
    traceId = span and span.traceId,
    spanId = span and span.spanId,
  }
end

-- An event is a log record with an event name (replaces span events, OTEP 4430).
function M.event(name, attributes, span, severity)
  M.log(severity or "INFO", nil, attributes, span, nil, name)
end

-- Metrics -------------------------------------------------------------------------------------
-- Counters and histograms are cumulative since launch (what Prometheus expects); gauges keep
-- the last value. Every flush resends the current state.

local BOUNDS = { 0.002, 0.004, 0.008, 0.0167, 0.0333, 0.05, 0.1, 0.25, 0.5, 1 } -- s, around 60/30 fps budgets

local function point(name, kind, unit, attributes)
  local m = M.metrics[name]
  if not m then
    m = { kind = kind, unit = unit, points = {} }
    M.metrics[name] = m
  end
  local key = {}
  for k, v in pairs(attributes or {}) do key[#key + 1] = k .. "=" .. tostring(v) end
  table.sort(key)
  key = table.concat(key, ",")
  if not m.points[key] then m.points[key] = { attributes = attrs(attributes or {}) } end
  return m.points[key]
end

function M.count(name, value, unit, attributes)
  if not finite(value) then return end
  local p = point(name, "sum", unit, attributes)
  p.asDouble = (p.asDouble or 0) + value
end

function M.gauge(name, value, unit, attributes)
  if not finite(value) then return end
  point(name, "gauge", unit, attributes).asDouble = value
end

function M.histogram(name, value, unit, attributes)
  if not finite(value) then return end
  local p = point(name, "histogram", unit, attributes)
  if not p.buckets then
    p.buckets, p.count, p.sum, p.min, p.max = {}, 0, 0, value, value
    for i = 1, #BOUNDS + 1 do p.buckets[i] = 0 end
  end
  local i = 1
  while i <= #BOUNDS and value > BOUNDS[i] do i = i + 1 end
  p.buckets[i] = p.buckets[i] + 1
  p.count, p.sum = p.count + 1, p.sum + value
  p.min, p.max = math.min(p.min, value), math.max(p.max, value)
end

-- Encoding ------------------------------------------------------------------------------------

local SCOPE = { name = SDK_NAME, version = SDK_VERSION }

function M.encode(spans)
  return json.encode({ resourceSpans = { {
    resource = { attributes = attrs(M.resource) },
    scopeSpans = { { scope = SCOPE, spans = spans } },
  } } })
end

function M.encode_logs(logs)
  local scopes = {}
  for name, records in pairs(logs) do
    scopes[#scopes + 1] = { scope = { name = name }, logRecords = records }
  end
  return json.encode({ resourceLogs = { {
    resource = { attributes = attrs(M.resource) },
    scopeLogs = scopes,
  } } })
end

function M.encode_metrics()
  local now, out = ns(M.now()), {}
  for name, m in pairs(M.metrics) do
    local points = {}
    for _, p in pairs(m.points) do
      local dp = { attributes = p.attributes, startTimeUnixNano = session_start, timeUnixNano = now }
      if m.kind == "histogram" then
        dp.count, dp.sum, dp.min, dp.max, dp.explicitBounds = tostring(p.count), p.sum, p.min, p.max, BOUNDS
        dp.bucketCounts = {}
        for i, c in ipairs(p.buckets) do dp.bucketCounts[i] = tostring(c) end
      else
        dp.asDouble = p.asDouble
      end
      points[#points + 1] = dp
    end
    local metric = { name = name, unit = m.unit }
    if m.kind == "sum" then
      metric.sum = { aggregationTemporality = 2, isMonotonic = true, dataPoints = points } -- 2 = CUMULATIVE
    elseif m.kind == "gauge" then
      metric.gauge = { dataPoints = points }
    else
      metric.histogram = { aggregationTemporality = 2, dataPoints = points }
    end
    out[#out + 1] = metric
  end
  return json.encode({ resourceMetrics = { {
    resource = { attributes = attrs(M.resource) },
    scopeMetrics = { { scope = SCOPE, metrics = out } },
  } } })
end

-- Export --------------------------------------------------------------------------------------

-- Runs in its own Lua state: blocks on the channel, POSTs each payload. A slow or missing
-- collector only delays this thread, never a frame.
-- Up to 3 attempts with backoff; 4xx means the payload itself is rejected, so no retry.
local WORKER = [[
require "love.thread"
local channel = ...
local socket, http, ltn12 = require "socket", require "socket.http", require "ltn12"
http.TIMEOUT = 10
while true do
  local job = channel:demand()
  for attempt = 1, 3 do
    local _, code = http.request {
      url = job.url,
      method = "POST",
      source = ltn12.source.string(job.body),
      headers = { ["content-type"] = "application/json", ["content-length"] = tostring(#job.body) },
    }
    if code == 200 then break end
    local permanent = type(code) == "number" and code >= 400 and code < 500
    if permanent or attempt == 3 then
      print("[otel] export to " .. job.url .. " failed: " .. tostring(code))
      break
    end
    socket.sleep(attempt)
  end
end
]]

local channel, worker

local function send(path, body)
  if not (love and love.thread) then return end -- outside the game (tests) there is nothing to send with
  if not worker then
    channel = love.thread.newChannel()
    worker = love.thread.newThread(WORKER)
    worker:start(channel)
  end
  local err = worker:getError()
  if err then return print("[otel] export thread died: " .. err) end
  channel:push({ url = M.endpoint .. path, body = body })
end

function M.flush()
  if #M.buffer > 0 then
    send("/v1/traces", M.encode(M.buffer))
    M.buffer = {}
  end
  if next(M.logs) then
    send("/v1/logs", M.encode_logs(M.logs))
    M.logs = {}
  end
  if next(M.metrics) then send("/v1/metrics", M.encode_metrics()) end
end

return M
