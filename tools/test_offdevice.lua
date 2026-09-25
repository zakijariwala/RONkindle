--[[
Off-device tests for duas.koplugin, run with plain LuaJIT (no KOReader UI).

  luajit tools/test_offdevice.lua <koreader-base dir> <duas.sqlite> <vectors.tsv>

Uses koreader-base's real lua-ljsqlite3 and ffi/zlib bindings against the
system libsqlite3/libz, and small stand-ins for KOReader's datastorage, lfs
and util. vectors.tsv comes from run_tests.sh (Python normalize() output).
]]

local base, db_path, vectors_path = arg[1], arg[2], arg[3]
assert(base and db_path and vectors_path, "usage: luajit test_offdevice.lua <koreader-base> <duas.sqlite> <vectors.tsv>")

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$") or "."
local plugin_dir = here .. "/../duas.koplugin"
package.path = table.concat({
    plugin_dir .. "/?.lua", base .. "/?.lua", base .. "/thirdparty/?.lua", package.path,
}, ";")

local ffi = require("ffi")
ffi.loadlib = function(name, version)
    return ffi.load(version and (name .. ".so." .. version) or name)
end

local tmp = os.getenv("TMPDIR") or "/tmp"
local data_dir = tmp .. "/duas-test-" .. os.time()
os.execute("mkdir -p '" .. data_dir .. "'")

package.preload["datastorage"] = function()
    return {
        getDataDir = function() return data_dir end,
        getSettingsDir = function() return data_dir .. "/settings" end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    local lfs = {}
    function lfs.attributes(path, what)
        local ok = os.execute("test -d '" .. path .. "'")
        if ok == 0 or ok == true then return what and "directory" or { mode = "directory" } end
        local f = io.open(path, "rb")
        if f then f:close() return what and "file" or { mode = "file" } end
        return nil
    end
    function lfs.dir(path)
        local p = io.popen("ls -a '" .. path .. "'")
        return function()
            local line = p:read("*l")
            if not line then p:close() end
            return line
        end
    end
    return lfs
end
package.preload["util"] = function()
    local util = {}
    function util.makePath(path) os.execute("mkdir -p '" .. path .. "'") return true end
    function util.trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
    function util.htmlEntitiesToUtf8(s)
        s = s:gsub("&#[xX](%x+);", function(h) return utf8char(tonumber(h, 16)) end)
        return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&amp;", "&"))
    end
    return util
end
function utf8char(cp) -- luacheck: ignore
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local failures, checks = 0, 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

-- ─── Normalisation parity with the Python builder ───────────────────────────
local Normalize = require("duasnormalize")
local n_vec, n_bad = 0, 0
for line in io.lines(vectors_path) do
    local input, expected = line:match("^(.-)\t(.*)$")
    if input then
        n_vec = n_vec + 1
        local got = Normalize.text(input)
        if got ~= expected then
            n_bad = n_bad + 1
            if n_bad <= 3 then print("normalize mismatch:\n  in:  " .. input .. "\n  py:  " .. expected .. "\n  lua: " .. got) end
        end
    end
end
check(n_vec > 0 and n_bad == 0, string.format("normalize parity: %d/%d vectors differ", n_bad, n_vec))
check(Normalize.matchExpression("  Dua-e  Kumail! ") == '"Dua"* "e"* "Kumail"*', "matchExpression splits on punctuation")
check(Normalize.matchExpression("،؟ ...") == nil, "matchExpression of punctuation only is nil")

-- ─── Database ───────────────────────────────────────────────────────────────
local DuasDB = require("duasdb")
local ok, err = DuasDB:open(db_path)
check(ok, "open db: " .. tostring(err))
check(tonumber(DuasDB:meta("schema")) == DuasDB.SCHEMA, "meta schema matches the plugin")
local cats = DuasDB:categories()
check(#cats == 5, "5 visible categories, got " .. #cats)
local top = DuasDB:children(cats[1].id, 0)
check(#top > 0, "top level of first category has children")

-- first node with a page, and first node with children, anywhere in the tree
local page_node, parent_node
local function walk(cat, parent, depth)
    for _, n in ipairs(DuasDB:children(cat, parent)) do
        if n.has_page and not page_node then page_node = n end
        if n.kids > 0 and not parent_node then parent_node = n end
        if n.kids > 0 and depth < 3 and not (page_node and parent_node) then walk(cat, n.id, depth + 1) end
    end
end
for _, c in ipairs(cats) do walk(c.id, 0, 0) end
check(page_node ~= nil, "found a node with a page")
check(parent_node ~= nil and #DuasDB:children(parent_node.cat, parent_node.id) == parent_node.kids,
    "kids count matches children()")

local body = DuasDB:pageBody(page_node.id)
check(body and #body > 0 and body:find('<div class="ln', 1, true), "page body decompresses to HTML")
local chain = DuasDB:ancestry(page_node.id)

-- long pages are split into parts; every line's part is recorded
local split = DuasDB:rows("SELECT id FROM nodes WHERE parts > 1 ORDER BY parts DESC LIMIT 1")[1]
check(split ~= nil, "some long pages are split into parts")
if split then
    local n = DuasDB:node(split[1])
    local sizes = DuasDB:rows("SELECT max(size) FROM pages")[1][1]
    check(sizes < 70000, "no part is larger than ~60 KB (" .. sizes .. ")")
    local last = DuasDB:pageBody(n.id, n.parts)
    local line = tonumber(last:match('id="l(%d+)"'))
    check(line and DuasDB:partOfLine(n.id, line) == n.parts, "partOfLine finds a line in the last part")
    local Pages0 = require("duaspages")
    local p2 = Pages0:ensure(DuasDB, n, 2)
    local id2, part2 = Pages0:nodeIdOf(p2)
    check(id2 == n.id and part2 == 2, "part files are named <node>_<part>-…")
    local f = io.open(p2, "rb"); local html2 = f:read("*all"); f:close()
    check(html2:find('href="duas:' .. n.id .. '/1"', 1, true) and html2:find("Part 2 of " .. n.parts, 1, true),
        "parts link to each other")
end
check(chain[#chain].id == page_node.id and chain[1].parent == 0, "ancestry runs from top level to node")

-- ─── Search ─────────────────────────────────────────────────────────────────
local function search(q)
    return DuasDB:search(Normalize.matchExpression(q), 200)
end
for _, q in ipairs({ "kumail", "KUMAIL", "mercy", "rehmat", "الحمد", "رحمن", "مہربان", "bismillaahir" }) do
    local hits, serr = search(q)
    check(hits and #hits > 0, "search '" .. q .. "' finds results (" .. tostring(serr or (hits and #hits)) .. ")")
end
-- search for a word typed without harakat must match voweled Arabic
local hits = search("الرحیم")
check(hits and #hits > 0, "Arabic search without harakat matches")

-- ─── Pages ──────────────────────────────────────────────────────────────────
local Pages = require("duaspages")
local path, perr = Pages:ensure(DuasDB, page_node)
check(path ~= nil, "Pages:ensure writes a file: " .. tostring(perr))
if path then
    local f = io.open(path, "rb"); local html = f:read("*all"); f:close()
    check(html:find("<title>", 1, true) and html:find('class="crumb"', 1, true), "page has title and breadcrumb")
    check(Pages:isOurs(path) and Pages:nodeIdOf(path) == page_node.id, "isOurs/nodeIdOf recognise the page")
    check(not Pages:isOurs("/mnt/us/documents/book.epub"), "isOurs rejects other files")
end

-- snippet of an English search hit
local hit = (search("mercy") or {})[1]
if hit and hit.line then
    local snip = Pages.snippet(DuasDB:pageBody(hit.node), hit.line, hit.lang, { "mercy" })
    check(snip and snip:lower():find("merc", 1, true), "snippet contains the search word: " .. tostring(snip))
    check(snip and not snip:find("<", 1, true), "snippet has no markup")
end

-- pages with images get their files
local img_rows = DuasDB:rows("SELECT node FROM images LIMIT 1")
if img_rows[1] then
    local n = DuasDB:node(img_rows[1][1])
    local p = Pages:ensure(DuasDB, n)
    local img = DuasDB:images(n.id)[1]
    local f = io.open(Pages.dir .. "/img/" .. img[1], "rb")
    local data = f and f:read("*all"); if f then f:close() end
    check(data and data:sub(2, 4) == "PNG", "image written as PNG for node " .. n.id)
    check(p ~= nil, "image page generated")
end

-- ─── Style ──────────────────────────────────────────────────────────────────
local Style = require("duasstyle")
local css_all = Style.css({ ar = true, tr = true, en = true, ru = true, ur = true, notes = true, vn = true, tj = true })
local css_some = Style.css({ ar = true, tr = false, en = true, ru = false, ur = true, notes = true, vn = false, tj = false })
check(not css_all:find("display: none !important", 1, true), "all shown: nothing hidden")
check(css_some:find(".x-tr {", 1, true) and css_some:find(".x-ru {", 1, true) and css_some:find(".x-vn {", 1, true)
    and css_some:find("sup.ws { display: none; }", 1, true), "hidden parts get display:none")
check(not css_some:find(".x-en {", 1, true), "shown parts are not hidden")

-- ─── main.lua smoke test with stand-in UI modules ───────────────────────────
local shown, events = {}, {}
local function stub(t) return function() return t end end
local Widget = {}
function Widget:extend(o) o = o or {}; setmetatable(o, { __index = self }); o.__index = o; return o end
function Widget:new(o) o = o or {}; setmetatable(o, self); self.__index = self; if o.init then o:init() end; return o end
package.preload["ui/widget/infomessage"] = stub(Widget:extend{})
package.preload["ui/widget/inputdialog"] = stub(Widget:extend{})
package.preload["ui/widget/container/widgetcontainer"] = stub(Widget:extend{})
package.preload["ui/widget/menu"] = stub(Widget:extend{})
package.preload["ui/widget/notification"] = stub({ notify = function() end, SOURCE_ALWAYS_SHOW = 1 })
package.preload["ui/uimanager"] = stub({ show = function(_, w) table.insert(shown, w) end, close = function() end,
    askForRestart = function() end })
package.preload["ui/event"] = stub({ new = function(_, name, arg) return { name = name, arg = arg } end })
package.preload["dispatcher"] = stub({ registerAction = function() end })
package.preload["logger"] = stub({ warn = function() end, dbg = function() end })
package.preload["gettext"] = stub(function(s) return s end)
package.preload["ffi/util"] = stub({ template = function(s, ...)
    local a = { ... }; return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end,
    copyFile = function() end })
package.preload["luasettings"] = stub({ open = function()
    local data = {}
    return { readSetting = function(_, k) return data[k] end, saveSetting = function(_, k, v) data[k] = v end,
             flush = function() end }
end })

local Duas = require("main")
-- The plugin closes the database whenever it opens a page; the checks below
-- query it directly, so reopen on demand.
local orig_rows = DuasDB.rows
DuasDB.rows = function(self, ...)
    if not self.conn then self:open(db_path) end
    return orig_rows(self, ...)
end
local page_path = Pages:ensure(DuasDB, page_node)
local switched
local link_mod = { onGotoLink = function() return "orig" end }
local style_mod = { getCssText = function() return "/* user tweaks */" end }
local ui = {
    document = { file = page_path, isXPointerInDocument = function() return true end },
    menu = { registerToMainMenu = function() end },
    styletweak = style_mod, link = link_mod,
    handleEvent = function(_, ev) table.insert(events, ev.name) end,
    switchDocument = function(_, file) switched = file end,
}
local plugin = Duas:new{ ui = ui, path = plugin_dir }
-- real findDB(): the database must be found in <data dir>/duas/
os.execute("mkdir -p '" .. data_dir .. "/duas' && cp '" .. db_path .. "' '" .. data_dir .. "/duas/duas.sqlite'")
check(plugin:findDB() == data_dir .. "/duas/duas.sqlite", "findDB finds <data dir>/duas/duas.sqlite")

local css = style_mod:getCssText()
check(css:find("/* user tweaks */", 1, true) and css:find("p.ar {", 1, true), "getCssText keeps user tweaks and adds ours")
check(plugin:setShown("en", false), "hiding English allowed")
check(style_mod:getCssText():find(".x-en { display: none", 1, true), "hidden English reaches the stylesheet")
check(events[#events] == "ApplyStyleSheet", "toggle re-applies the stylesheet")
for _, k in ipairs({ "ar", "tr", "ru" }) do plugin:setShown(k, false) end
check(plugin:setShown("ur", false) == false and plugin:isShown("ur"), "last visible text part cannot be hidden")

local target = DuasDB:children(page_node.cat, page_node.parent)
local other
for _, n in ipairs(target) do if n.has_page and n.id ~= page_node.id then other = n break end end
if other then
    check(link_mod:onGotoLink({ xpointer = "duas:" .. other.id }) == true and switched and switched:find("/" .. other.id .. "_", 1, true),
        "duas: link opens the linked page")
end
check(link_mod:onGotoLink({ xpointer = "#some_anchor" }) == "orig", "other links go to KOReader")

-- alias entries open their target page, verse links carry a line
local alias = DuasDB:rows("SELECT id, redirect FROM nodes WHERE redirect IS NOT NULL LIMIT 1")[1]
if alias then
    switched = nil
    plugin:openNode(alias[1])
    check(switched and switched:find("/" .. alias[2] .. "_", 1, true), "alias entry opens its target page")
end
local verse_link
for _, r in ipairs(DuasDB:rows("SELECT node FROM pages")) do
    local b = DuasDB:pageBody(r[1])
    local t, l = b:match('href="duas:(%d+):(%d+)"')
    if t then verse_link = { tonumber(t), tonumber(l) } break end
end
check(verse_link ~= nil, "some page links to a specific verse")
if verse_link then
    switched = nil
    local goto_line
    ui.switchDocument = function(_, file, _, cb) switched = file; goto_line = cb end
    check(link_mod:onGotoLink({ xpointer = "duas:" .. verse_link[1] .. ":" .. verse_link[2] }) == true, "verse link handled")
    local jumped
    goto_line({ rolling = { onGotoXPointer = function(_, xp) jumped = xp end },
                document = { isXPointerInDocument = function() return true end } })
    check(jumped == "#l" .. verse_link[2], "verse link jumps to its line")
end
local seen_keys, dup = {}, false
for _, it in ipairs(plugin:searchItems(DuasDB, "kumail") or {}) do
    local k = it.node.id .. ":" .. tostring(it.line)
    if seen_keys[k] then dup = true end
    seen_keys[k] = true
end
check(not dup, "search lists each line once")

local items = plugin:searchItems(DuasDB, "mercy")
check(items and #items > 0 and items[1].text:find("\n", 1, true), "search items carry a snippet line")
check(plugin:toggleBookmark(page_node) == true and plugin:isBookmarked(page_node.id), "bookmark added")
check(#plugin:bookmarksView().build() == 1, "bookmark listed")
check(plugin:toggleBookmark(page_node) == false and not plugin:isBookmarked(page_node.id), "bookmark removed")
local root = plugin:rootView().build()
check(#root == 3 + #cats, "root view lists shortcuts and categories")
check(#plugin:quickView().build() > 6, "Path to Supplication list resolves ids")
local views = plugin:viewsFor(page_node, false)
check(#views == #chain + 1, "viewsFor builds root, category and ancestor levels")

print(string.format("\n%d checks, %d failed", checks, failures))
os.execute("rm -rf '" .. data_dir .. "'")
os.exit(failures == 0 and 0 or 1)
