-- The export thread from otel.lua, run in LÖVE: posts a tiny payload to each URL and prints the
-- status code or error it got. Run from the repo root with the game's LÖVE, for example on macOS:
--   OTEL_TEST_URLS="http://127.0.0.1:4318/v1/traces https://example.com/v1/traces" \
--     /path/to/love.app/Contents/MacOS/love tests/export
-- OTEL_TEST_BACKEND picks an HTTPS backend (lua_https, cfnetwork, curl); empty picks the first that
-- loads, as the game does. OTEL_LUA overrides the path to otel.lua.
package.preload.json = function() return { encode = function() return "{}" end } end
local otel = assert(loadfile(os.getenv("OTEL_LUA") or "mod/otel-trace/otel.lua"))()
local backend = os.getenv("OTEL_TEST_BACKEND")
if backend == "" then backend = nil end

function love.load()
  local jobs, reply = love.thread.newChannel(), love.thread.newChannel()
  local worker = love.thread.newThread(otel.WORKER)
  worker:start(jobs, backend)
  for url in (os.getenv("OTEL_TEST_URLS") or ""):gmatch("%S+") do
    local t0 = love.timer.getTime()
    jobs:push({ url = url, body = '{"resourceSpans":[]}', reply = reply })
    local result = reply:demand(60)
    print(string.format("RESULT %-48s %s (%.1fs)", url, tostring(result), love.timer.getTime() - t0))
    if worker:getError() then print("THREAD ERROR " .. worker:getError()) break end
  end
  love.event.quit()
end
