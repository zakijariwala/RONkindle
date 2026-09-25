--[[
Benchmark driver for duas.koplugin (a KOReader user patch, like
2-duas-emu-test.lua). Times the operations that matter on a slow device,
polling for completion instead of fixed waits, and records memory.

  DRIVER=2-duas-bench.lua PHASES=1 RUN_WRAPPER=... tools/emulator/run_emulator_tests.sh duas.sqlite /tmp/bench

Writes <workdir>/shots/bench.txt. Works with any plugin version that has
openNode(id, line), onDuasBrowse(), onDuasToggle(key) and searchItems(db, q).
]]

local UIManager = require("ui/uimanager")
local time = require("ui/time")

local SHOTS = os.getenv("DUAS_SHOTS") or "/tmp"
local TIMEOUT = tonumber(os.getenv("DUAS_BENCH_TIMEOUT")) or 1800 -- seconds per operation

local out = {}
local function log(...)
    local line = table.concat({ ... }, "\t")
    print("DUASBENCH", line)
    table.insert(out, line)
end
local function mem()
    local f = io.open("/proc/self/status")
    if not f then return "?" end
    local s = f:read("*all")
    f:close()
    return string.format("rss %d MB, peak %d MB",
        math.floor((tonumber(s:match("VmRSS:%s*(%d+)")) or 0) / 1024),
        math.floor((tonumber(s:match("VmHWM:%s*(%d+)")) or 0) / 1024))
end

local function FM() return require("apps/filemanager/filemanager").instance end
local function RUI() return require("apps/reader/readerui").instance end
local function P()
    local r = RUI()
    if r and r.duas then return r.duas end
    local f = FM()
    return f and f.duas
end
local function docIs(id)
    local r = RUI()
    local f = r and r.document and r.document.file
    return f and (f:match("/" .. id .. "_%d+%-[^/]*%.html$") or f:match("/" .. id .. "%-[^/]*%.html$")) ~= nil
end

local ops = {}
local function op(name, start, done)
    table.insert(ops, { name = name, start = start, done = done })
end

local function finish()
    local f = io.open(SHOTS .. "/bench.txt", "w")
    if f then
        f:write(table.concat(out, "\n") .. "\n")
        f:close()
    end
    UIManager:quit(0)
end

local function runNext()
    local o = table.remove(ops, 1)
    if not o then return finish() end
    local t0 = time.realtime()
    local ok, err = pcall(o.start)
    if not ok then
        log(o.name, "ERROR", tostring(err))
        return UIManager:scheduleIn(1, runNext)
    end
    local function poll()
        local ok2, res = pcall(o.done or function() return true end)
        local secs = time.to_s(time.realtime() - t0)
        if ok2 and res then
            UIManager:forceRePaint()
            secs = time.to_s(time.realtime() - t0)
            log(o.name, string.format("%.1f s", secs), mem())
            return UIManager:scheduleIn(0.5, runNext)
        end
        if secs > TIMEOUT then
            log(o.name, "TIMEOUT", mem())
            return UIManager:scheduleIn(0.5, runNext)
        end
        UIManager:scheduleIn(0.1, poll)
    end
    poll()
end

local state = {}
op("startup to file manager", function() end, function() return FM() ~= nil end)
op("open browser", function() P():onDuasBrowse() end, function() return P().browser ~= nil end)
op("open Fateha (short page)", function() P():openNode(1074) end, function() return docIs(1074) end)
op("open Baqarah (longest page)", function() P():openNode(1075) end, function() return docIs(1075) end)
op("hide English", function()
    state.pages = RUI().document:getPageCount()
    P():onDuasToggle("en")
end, function() return RUI().document:getPageCount() ~= state.pages end)
op("show English again", function()
    state.pages = RUI().document:getPageCount()
    P():onDuasToggle("en")
end, function() return RUI().document:getPageCount() ~= state.pages end)
op("search 'kumail'", function()
    state.n = #(P():searchItems(P():getDB(), "kumail") or {})
end)
op("search 'allah' (very common)", function()
    state.n = #(P():searchItems(P():getDB(), "allah") or {})
end)
op("jump to Baqarah 2:255", function()
    local db = P():getDB()
    local r = db:rows("SELECT line FROM texts WHERE node = 1075 AND lang = 'ar' ORDER BY id")[256]
    state.line = r[1]
    state.file = RUI().document.file
    P():openNode(1075, state.line)
end, function()
    local r = RUI()
    return r and r.document and r.document:isXPointerInDocument("#l" .. state.line)
        and r.document:getPageFromXPointer("#l" .. state.line) == r.document:getCurrentPage()
end)

UIManager:scheduleIn(1, runNext)
