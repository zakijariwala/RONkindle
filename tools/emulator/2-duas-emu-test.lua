--[[
In-app test driver for duas.koplugin, installed as a KOReader user patch
(priority 2 = runs once UIManager is ready). Driven by run_emulator_tests.sh.

It drives the plugin the way a user would (browser, reader, toggles, links,
search, bookmarks, menus, dispatcher actions, font install), checks results
against the real KOReader/crengine state, takes screenshots and quits.

Environment:
  DUAS_SHOTS    directory for screenshots and results.txt
  DUAS_PHASE    "1" main run, "2" after restart (persistence + installed font)
]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local SHOTS = os.getenv("DUAS_SHOTS") or "/tmp"
local PHASE = os.getenv("DUAS_PHASE") or "1"
-- Multiplies every wait, for runs on a throttled CPU (see run_emulator_tests.sh).
local SLOW = tonumber(os.getenv("DUAS_SLOW")) or 1

local function memKB()
    local f = io.open("/proc/self/status")
    if not f then return 0, 0 end
    local s = f:read("*all")
    f:close()
    return tonumber(s:match("VmRSS:%s*(%d+)")) or 0, tonumber(s:match("VmHWM:%s*(%d+)")) or 0
end

local results = {}
local function log(...)
    print("DUASTEST", ...)
end
local function check(cond, msg)
    table.insert(results, { ok = cond and true or false, msg = msg })
    log(cond and "PASS" or "FAIL", msg)
end

local shot_n = 0
local function shot(name)
    UIManager:forceRePaint()
    shot_n = shot_n + 1
    local path = string.format("%s/p%s-%02d-%s.png", SHOTS, PHASE, shot_n, name)
    Screen:shot(path)
    log("SHOT", path)
end

-- Page area only (the footer's progress bar is drawn slightly differently
-- after a reload, which has nothing to do with the page's rendering).
local function pageShot(path)
    UIManager:forceRePaint()
    local h = Screen:getHeight() - Screen:scaleBySize(60)
    Screen.bb:viewport(0, 0, Screen:getWidth(), h):writePNG(path)
end

local function FM() return require("apps/filemanager/filemanager").instance end
local function RUI() return require("apps/reader/readerui").instance end
local function P()
    local r = RUI()
    if r and r.duas then return r.duas end
    local f = FM()
    return f and f.duas
end
local function topWidget()
    local stack = UIManager._window_stack
    return stack[#stack] and stack[#stack].widget
end
local function docFile()
    local r = RUI()
    return r and r.document and r.document.file
end
local function docIs(node_id)
    local f = docFile()
    return f and f:match("/" .. node_id .. "_%d+%-[^/]*%.html$") ~= nil
end
local function docPart()
    local f = docFile()
    return f and tonumber(f:match("/%d+_(%d+)%-[^/]*%.html$"))
end
local function now()
    return require("ffi/util").getTimestamp and require("ffi/util").getTimestamp() or os.time()
end

-- ─── Step queue ─────────────────────────────────────────────────────────────
local queue = {}
local function step(name, fn, delay)
    table.insert(queue, { name = name, fn = fn, delay = (delay or 1) * SLOW })
end
local function waitFor(name, cond, timeout)
    table.insert(queue, { name = name, wait = cond, timeout = (timeout or 30) * SLOW })
end

local finish
local function runNext()
    local s = table.remove(queue, 1)
    if not s then return finish() end
    if s.wait then
        local waited = 0
        local function poll()
            local ok, res = pcall(s.wait)
            if ok and res then
                log("WAITED", s.name, string.format("%.2fs", waited))
                UIManager:scheduleIn(0.7 * SLOW, runNext)
                return
            end
            waited = waited + 0.25
            if waited > s.timeout then
                check(false, "timeout waiting for " .. s.name)
                UIManager:scheduleIn(0.5, runNext)
                return
            end
            UIManager:scheduleIn(0.25, poll)
        end
        poll()
    else
        UIManager:scheduleIn(s.delay, function()
            local rss, hwm = memKB()
            log("STEP", s.name, string.format("[rss %d MB, peak %d MB]", math.floor(rss / 1024), math.floor(hwm / 1024)))
            local ok, err = xpcall(s.fn, debug.traceback)
            if not ok then check(false, s.name .. " crashed: " .. tostring(err)) end
            runNext()
        end)
    end
end

finish = function()
    local failed = 0
    local f = io.open(SHOTS .. "/results-phase" .. PHASE .. ".txt", "w")
    for _, r in ipairs(results) do
        if not r.ok then failed = failed + 1 end
        if f then f:write((r.ok and "PASS " or "FAIL ") .. r.msg .. "\n") end
    end
    if f then
        f:write(string.format("\n%d checks, %d failed\n", #results, failed))
        f:close()
    end
    log(string.format("SUMMARY phase %s: %d checks, %d failed", PHASE, #results, failed))
    UIManager:quit(failed == 0 and 0 or 1)
end

-- Helpers used by several steps
local function browserItems()
    local b = P() and P().browser
    return b and b.item_table or {}
end
local function findItem(text_pattern)
    for _, item in ipairs(browserItems()) do
        if item.text and item.text:find(text_pattern) then return item end
    end
end
local function select(text_pattern)
    local item = findItem(text_pattern)
    check(item ~= nil, "browser has item matching '" .. text_pattern .. "'")
    if item then P().browser:onMenuSelect(item) end
    return item
end
-- index of the <div> child of <body> that contains the given xpointer
local function bodyDivIndex(xp)
    return xp and tonumber(xp:match("/body/div%[(%d+)%]"))
end
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*all")
    f:close()
    return data
end
local function isConfirmBox(w)
    return w and w.ok_callback ~= nil and w.cancel_text ~= nil
end
local function findMenuItem(tab_item_table, text)
    for tab_idx, tab in ipairs(tab_item_table) do
        for _, item in ipairs(tab) do
            if item.text == text then return tab_idx, item end
        end
    end
end

-- Force grayscale like a Kindle, and a known state
G_reader_settings:saveSetting("color_rendering", false)

local state = {}

if PHASE == "1" then
    -- ── File manager ──────────────────────────────────────────────────────
    step("plugin loaded in file manager", function()
        check(FM() ~= nil and FM().duas ~= nil, "plugin instance registered in the file manager")
        shot("filemanager")
    end, 2)

    step("file manager menu has Duas under Tools", function()
        local menu = FM().menu
        menu:onShowMenu()
        local tab_idx, item = findMenuItem(menu.tab_item_table, "Duas")
        check(item ~= nil, "Duas entry present in file manager menu")
        local touchmenu = menu.menu_container and menu.menu_container[1]
        if item and touchmenu then
            touchmenu:switchMenuTab(tab_idx)
            touchmenu:onMenuSelect(item)
            state.fm_menu_tab = tab_idx
        end
    end)
    step("file manager Duas submenu", function()
        shot("fm-menu-duas")
        FM().menu:onCloseFileManagerMenu()
        check(state.fm_menu_tab ~= 1, "Duas is not in the first (file browser) tab")
    end)

    -- ── Browser ───────────────────────────────────────────────────────────
    step("open browser", function()
        P():onDuasBrowse()
        local b = P().browser
        check(b ~= nil and topWidget() == b, "browser shown on top")
        local items = browserItems()
        check(#items == 8, "root lists 3 shortcuts + 5 categories (got " .. #items .. ")")
        shot("browser-root")
    end)
    step("category level", function()
        select("^Qur")
        check(#browserItems() > 3, "Qur'an category lists its sections")
        shot("browser-quran")
    end)
    step("surah list", function()
        select("^Surah")
        check(#browserItems() == 114, "Surahs lists 114 surahs (got " .. #browserItems() .. ")")
        shot("browser-surahs")
    end)
    step("hold to bookmark in browser", function()
        local item = findItem("Fateha")
        P().browser:onMenuHold(item)
        check(P():isBookmarked(item.node.id), "hold bookmarks the item")
        check(findItem("Fateha").mandatory == "★", "bookmarked item shows ★")
        shot("browser-bookmarked")
        P().browser:onMenuHold(findItem("Fateha"))
        check(not P():isBookmarked(item.node.id), "second hold removes the bookmark")
    end)
    step("return goes up one level", function()
        P().browser:onReturn()
        check(findItem("^Surah") ~= nil, "return shows the Qur'an level again")
        select("^Surah")
    end)
    step("open Fateha from the browser", function()
        state.t_open = now()
        select("Fateha")
    end)
    waitFor("reader shows Fateha (1074)", function() return docIs(1074) end)

    -- ── Reader ────────────────────────────────────────────────────────────
    step("reader page and hooks", function()
        check(P() ~= nil and P() == RUI().duas, "plugin instance registered in the reader")
        check(P().browser == nil, "browser closed when the page opened")
        local css = RUI().styletweak:getCssText()
        check(css and css:find("p.ar {", 1, true), "stylesheet hook active in the reader")
        check(RUI().document:getPageCount() >= 1, "Fateha rendered")
        shot("reader-fateha")
    end, 1.5)

    step("open Baqarah (largest surah) and time it", function()
        state.t_open = now()
        P():openNode(1075)
    end)
    waitFor("reader shows Baqarah (1075)", function() return docIs(1075) end, 60)
    step("Baqarah opened", function()
        log("TIMING open Baqarah", string.format("%.2fs", now() - state.t_open))
        state.pages_all = RUI().document:getPageCount()
        check(docPart() == 1 and state.pages_all > 10, "Baqarah part 1 paginates (" .. state.pages_all .. " pages)")
        RUI():handleEvent(Event:new("GotoPage", 12))
    end, 1.5)
    step("position before toggling", function()
        state.xp = RUI().rolling:getBookLocation()
        state.div = bodyDivIndex(state.xp)
        check(state.div ~= nil, "top of page 20 is inside a line block (" .. tostring(state.xp) .. ")")
        shot("baqarah-p20-all")
    end)
    step("hide English", function()
        state.t_toggle = now()
        P():onDuasToggle("en")
    end)
    step("English hidden: fewer pages, same place", function()
        log("TIMING toggle English", string.format("%.2fs", now() - state.t_toggle))
        check(not P():isShown("en"), "English marked hidden")
        local pages = RUI().document:getPageCount()
        check(pages < state.pages_all, "page count drops without English (" .. state.pages_all .. " → " .. pages .. ")")
        local div = bodyDivIndex(RUI().rolling:getBookLocation())
        check(div and math.abs(div - state.div) <= 1, "reading position kept (line block " .. tostring(state.div) .. " → " .. tostring(div) .. ")")
        check(not isConfirmBox(topWidget()), "no reload prompt after toggling")
        shot("baqarah-no-english")
        state.toggled_shot = SHOTS .. "/cmp-toggled.png"
        pageShot(state.toggled_shot)
        state.toggled_page = RUI():getCurrentPage()
        state.doc_before = RUI().document
        RUI():reloadDocument()
    end, 2)
    waitFor("Baqarah fully reloaded", function()
        return RUI() and RUI().document ~= state.doc_before and docIs(1075)
    end, 60)
    step("toggled page renders the same as a fresh load", function()
        RUI():handleEvent(Event:new("GotoPage", state.toggled_page))
    end)
    step("compare toggled vs reloaded", function()
        shot("baqarah-no-english-reloaded")
        local reloaded = SHOTS .. "/cmp-reloaded.png"
        pageShot(reloaded)
        local a, b = readFile(state.toggled_shot), readFile(reloaded)
        check(a and b and a == b, "page after toggling is pixel-identical to the same page after a full reload")
    end, 1.5)
    step("hide everything but Arabic", function()
        for _, k in ipairs({ "tr", "ru", "ur", "notes", "vn" }) do P():setShown(k, false) end
    end)
    step("Arabic only", function()
        local pages = RUI().document:getPageCount()
        check(pages < state.pages_all / 2, "Arabic-only is much shorter (" .. pages .. " pages)")
        shot("baqarah-arabic-only")
        check(P():setShown("ar", false) == false and P():isShown("ar"), "hiding the last text part is refused")
    end, 2)
    step("refusal message shown", function()
        shot("refuse-last-part")
        local w = topWidget()
        if w and w.text and w.text:find("stay visible") then UIManager:close(w) end
    end, 0.5)
    step("restore all parts", function()
        for _, k in ipairs({ "en", "tr", "ru", "ur", "notes", "vn" }) do P():setShown(k, true) end
    end)
    step("all parts back", function()
        check(RUI().document:getPageCount() == state.pages_all, "page count restored (" .. RUI().document:getPageCount() .. ")")
    end, 2)

    step("dispatcher action toggles verse numbers", function()
        require("dispatcher"):execute({ duas_toggle_vn = true })
    end)
    step("verse numbers hidden via dispatcher", function()
        check(not P():isShown("vn"), "duas_toggle_vn dispatcher action hides verse numbers")
        require("dispatcher"):execute({ duas_toggle_vn = true })
    end, 1.5)
    step("verse numbers back", function()
        check(P():isShown("vn"), "second dispatcher call shows verse numbers")
    end, 1.5)

    -- ── Parts of a long page ──────────────────────────────────────────────
    step("next part link", function()
        RUI():handleEvent(Event:new("GotoPage", RUI().document:getPageCount()))
    end)
    step("tap 'Part 2 ›'", function()
        local target
        for _, l in ipairs(RUI().document:getPageLinks() or {}) do
            if l.uri == "duas:1075/2" then target = l end
        end
        check(target ~= nil, "last page of part 1 links to part 2")
        if target then
            local x = math.floor((target.start_x + target.end_x) / 2)
            RUI().link:onTap(nil, { ges = "tap", pos = Geom:new{ x = x, y = target.start_y + Screen:scaleBySize(5), w = 0, h = 0 } })
        end
    end)
    waitFor("Baqarah part 2 open", function() return docIs(1075) and docPart() == 2 end)
    step("verse 255 (Ayat al-Kursi) opens its part", function()
        local db = P():getDB()
        local r = db:rows("SELECT line FROM texts WHERE node = 1075 AND lang = 'ar' ORDER BY id")[255 + 1]
        state.ak_line = r and r[1]
        state.ak_part = state.ak_line and db:partOfLine(1075, state.ak_line)
        P():openNode(1075, state.ak_line)
    end)
    waitFor("verse's part open", function() return docIs(1075) and docPart() == state.ak_part end)
    step("landed on the verse", function()
        local doc = RUI().document
        check(state.ak_part and state.ak_part > 1, "late verse lives in a later part (" .. tostring(state.ak_part) .. ")")
        check(doc:getPageFromXPointer("#l" .. state.ak_line) == doc:getCurrentPage(), "jump lands on the verse inside its part")
        shot("baqarah-later-part")
        check(require("duasdb").conn == nil, "database closed while reading")
    end, 1.5)

    -- ── Links ─────────────────────────────────────────────────────────────
    step("open Fateha again for link test", function() P():openNode(1074) end)
    waitFor("Fateha open", function() return docIs(1074) end)
    step("go to last page", function()
        RUI():handleEvent(Event:new("GotoPage", RUI().document:getPageCount()))
    end)
    step("tap the 'Baqarah ›' link", function()
        shot("fateha-last-page")
        local links = RUI().document:getPageLinks() or {}
        local target
        for _, l in ipairs(links) do
            if (l.uri or ""):find("^duas:") then
                log("LINK", l.uri, l.start_x, l.start_y, l.end_x, l.end_y)
                if l.uri == "duas:1075" then target = l end
            end
        end
        check(target ~= nil, "page has a duas:1075 link (" .. #links .. " links on page)")
        if target then
            local x = math.floor((target.start_x + target.end_x) / 2)
            local y = target.start_y + Screen:scaleBySize(5)
            local href = RUI().document:getLinkFromPosition({ x = x, y = y })
            check(href == "duas:1075", "crengine reports the tapped href (" .. tostring(href) .. ")")
            RUI().link:onTap(nil, { ges = "tap", pos = Geom:new{ x = x, y = y, w = 0, h = 0 } })
        end
    end)
    waitFor("tap opened Baqarah", function() return docIs(1075) end)
    step("link opened Baqarah", function()
        check(true, "tapping a duas: link opens the linked page")
        shot("after-link-tap")
    end)

    -- ── Search ────────────────────────────────────────────────────────────
    step("search English", function()
        state.t_search = now()
        P():search("kumail")
        log("TIMING search kumail", string.format("%.2fs", now() - state.t_search))
        local items = browserItems()
        check(#items > 0, "search 'kumail' has results (" .. #items .. ")")
        check(items[1] and items[1].text:find("\n", 1, true), "results carry a snippet line")
        shot("search-kumail")
    end)
    step("open a result with a line", function()
        for _, item in ipairs(browserItems()) do
            if item.line then state.hit = item break end
        end
        check(state.hit ~= nil, "a result points at a line")
        if state.hit then P().browser:onMenuSelect(state.hit) end
    end)
    waitFor("result page open", function() return state.hit and docIs(state.hit.node.id) end)
    step("jumped to the matching line", function()
        local doc = RUI().document
        local want = doc:getPageFromXPointer("#l" .. state.hit.line)
        local have = doc:getCurrentPage()
        check(want and want == have, "search result lands on the line's page (want " .. tostring(want) .. ", at " .. tostring(have) .. ")")
        shot("search-result-opened")
    end, 1.5)
    step("search Arabic without harakat", function()
        local items = P():searchItems(P():getDB(), "الحمد لله رب العالمین")
        check(items and #items > 0, "Arabic search without harakat finds results (" .. tostring(items and #items) .. ")")
        items = P():searchItems(P():getDB(), "مہربان")
        check(items and #items > 0, "Urdu search finds results")
        items = P():searchItems(P():getDB(), "Rehmat")
        check(items and #items > 0, "Roman Urdu search finds results")
        items = P():searchItems(P():getDB(), "zzqxnotaword")
        check(items and #items == 0, "nonsense search returns no results")
    end)
    step("search results in browser for Arabic", function()
        P():search("الرحیم")
        shot("search-arabic")
        if P().browser then P().browser:onClose() end
    end)

    -- ── Reader menu ───────────────────────────────────────────────────────
    step("reader menu has Duas in the navigation tab", function()
        local menu = RUI().menu
        menu:onShowMenu()
        local tab_idx, item = findMenuItem(menu.tab_item_table, "Duas")
        check(item ~= nil and tab_idx == 1, "Duas is in the first (navigation) tab (tab " .. tostring(tab_idx) .. ")")
        local touchmenu = menu.menu_container and menu.menu_container[1]
        if item and touchmenu then
            touchmenu:switchMenuTab(tab_idx)
            touchmenu:onMenuSelect(item)
            state.touchmenu = touchmenu
        end
    end)
    step("Duas submenu in reader", function()
        shot("reader-menu-duas")
        local tm = state.touchmenu
        local bm_item
        for _, it in ipairs(tm.item_table) do
            local text = it.text_func and it.text_func() or it.text
            if text == "Bookmark this page" then bm_item = it end
        end
        check(bm_item ~= nil, "'Bookmark this page' offered on a Duas page")
        if bm_item then tm:onMenuSelect(bm_item) end
        check(P():isBookmarked(P():currentNodeId()), "menu bookmarks the current page")
    end)
    step("Show submenu", function()
        local tm = state.touchmenu
        for _, it in ipairs(tm.item_table) do
            if it.text == "Show" then tm:onMenuSelect(it) break end
        end
    end)
    step("toggle Roman Urdu from the Show submenu", function()
        shot("reader-menu-show")
        local tm = state.touchmenu
        for _, it in ipairs(tm.item_table) do
            if it.text == "Roman Urdu" then tm:onMenuSelect(it) break end
        end
    end)
    step("Roman Urdu toggled from menu", function()
        check(not P():isShown("ru"), "menu checkbox hides Roman Urdu")
        shot("reader-menu-show-ru-off")
        local tm = state.touchmenu
        for _, it in ipairs(tm.item_table) do
            if it.text == "Roman Urdu" then tm:onMenuSelect(it) break end
        end
    end, 2)
    step("close reader menu", function()
        check(P():isShown("ru"), "menu checkbox shows Roman Urdu again")
        RUI().menu:onCloseReaderMenu()
    end, 2)

    -- ── Bookmarks, shortcuts, browsing from the reader ─────────────────────
    step("bookmarks view", function()
        P():onDuasBookmarks()
        local items = browserItems()
        check(#items == 1, "bookmarks list has the bookmarked page (" .. #items .. ")")
        shot("bookmarks")
        P().browser:onClose()
    end)
    step("Path to Supplication", function()
        P():onDuasQuick()
        local nodes = 0
        for _, it in ipairs(browserItems()) do if it.node then nodes = nodes + 1 end end
        check(nodes >= 40, "Path to Supplication lists its entries (" .. nodes .. ")")
        shot("path-to-supplication")
    end)
    step("open Dua e Kumail from shortcuts (an alias entry)", function()
        select("Kumail")
    end)
    waitFor("Kumail alias opens the real Dua-e-Kumail page (1285)", function() return docIs(1285) end)
    step("Kumail page", function()
        shot("dua-kumail")
    end, 1.5)
    step("browse from the reader starts at the current section", function()
        P():onDuasBrowse()
        local here = P():currentNodeId()
        local found = false
        for _, it in ipairs(browserItems()) do
            if it.node and it.node.id == here then found = true end
        end
        check(found, "browser opens on the level containing the current page")
        shot("browse-from-reader")
        P().browser:onClose()
    end)

    -- ── Inline and verse links ─────────────────────────────────────────────
    step("step-numbered link list (Namaz-e-Shab)", function() P():openNode(1224) end)
    waitFor("Namaz-e-Shab open", function() return docIs(1224) end)
    step("Namaz-e-Shab page", function()
        local links = RUI().document:getPageLinks() or {}
        local n = 0
        for _, l in ipairs(links) do if (l.uri or ""):find("^duas:") then n = n + 1 end end
        RUI():handleEvent(Event:new("GotoPage", RUI().document:getPageCount()))
        state.nsl = n
    end, 1.5)
    step("Namaz-e-Shab last page", function()
        local links = RUI().document:getPageLinks() or {}
        local n = 0
        for _, l in ipairs(links) do if (l.uri or ""):find("^duas:") then n = n + 1 end end
        check(n + state.nsl >= 5, "Namaz-e-Shab links to its 5 parts (" .. (n + state.nsl) .. " links seen)")
        shot("namaz-e-shab-links")
    end, 1.5)
    step("verse link opens the exact verse", function()
        RUI().link:onGotoLink({ xpointer = "duas:1190:1010080" })
    end)
    waitFor("verse page open", function() return docIs(1190) end)
    step("verse link landed", function()
        local doc = RUI().document
        check(doc:getPageFromXPointer("#l1010080") == doc:getCurrentPage(), "verse link lands on the verse's page")
        shot("verse-link")
    end, 1.5)
    step("page with inline links in notes", function() P():openNode(1403) end)
    waitFor("inline-link page open", function() return docIs(1403) end)
    step("inline links rendered", function()
        local n = 0
        for p = 1, math.min(RUI().document:getPageCount(), 6) do
            RUI():handleEvent(Event:new("GotoPage", p))
            for _, l in ipairs(RUI().document:getPageLinks() or {}) do
                if (l.uri or ""):find("^duas:") then n = n + 1 end
            end
        end
        check(n > 0, "inline <Name> references are tappable links (" .. n .. " on the first pages)")
        RUI():handleEvent(Event:new("GotoPage", 1))
    end, 1.5)
    step("inline links screenshot", function() shot("inline-links") end, 1)

    -- ── Images ────────────────────────────────────────────────────────────
    step("open a page with images", function()
        local rows = require("duasdb"):rows("SELECT node FROM images LIMIT 1")
        state.img_node = rows[1] and rows[1][1]
        check(state.img_node ~= nil, "database has image pages")
        if state.img_node then P():openNode(state.img_node) end
    end)
    waitFor("image page open", function() return state.img_node and docIs(state.img_node) end)
    step("image page", function()
        shot("image-page")
        local img = require("duasdb"):images(state.img_node)[1]
        local f = io.open(require("duaspages").dir .. "/img/" .. img[1], "rb")
        check(f ~= nil, "image file written next to the page")
        if f then f:close() end
    end, 1.5)

    -- ── Folder node via openNode ──────────────────────────────────────────
    step("openNode on a section without a page opens the browser there", function()
        P():openNode(1568) -- Surahs
        check(P().browser ~= nil and #browserItems() == 114, "section opens in the browser")
        P().browser:onClose()
    end)

    -- ── Font install ──────────────────────────────────────────────────────
    step("install Amiri", function()
        local orig = UIManager.askForRestart
        UIManager.askForRestart = function(_, msg) state.restart_msg = msg end
        P():installFont()
        UIManager.askForRestart = orig
        check(P():isFontInstalled(), "Amiri copied to " .. P():fontTarget())
        check(state.restart_msg ~= nil, "restart requested after installing the font")
    end)
    step("screenshot Fateha before Amiri", function() P():openNode(1074) end)
    waitFor("Fateha open", function() return docIs(1074) end)
    step("Fateha page 1", function() RUI():handleEvent(Event:new("GotoPage", 1)) end)
    step("Fateha with default Arabic font", function()
        shot("fateha-default-font")
    end, 1.5)
end

if PHASE == "2" then
    step("settings persisted across restart", function()
        check(FM() == nil or FM().duas ~= nil, "plugin loaded after restart")
        local p = P()
        check(p and p:isShown("ar") and p:isShown("en"), "toggles restored")
        check(p and #p:getBookmarks() == 1, "bookmark persisted (" .. tostring(p and #p:getBookmarks()) .. ")")
        local FontList = require("fontlist")
        local found = false
        for _, path in ipairs(FontList.fontlist or {}) do
            if path:find("Amiri", 1, true) then found = true end
        end
        check(found, "KOReader picked up the installed Amiri font")
        p:openNode(1074)
    end, 2)
    waitFor("Fateha open", function() return docIs(1074) end)
    step("Fateha page 1", function() RUI():handleEvent(Event:new("GotoPage", 1)) end)
    step("Fateha with Amiri", function()
        shot("fateha-amiri")
        local before
        for name in require("libs/libkoreader-lfs").dir(SHOTS) do
            if name:match("^p1%-%d+%-fateha%-default%-font%.png$") then before = SHOTS .. "/" .. name end
        end
        local a, b = before and readFile(before), readFile(SHOTS .. string.format("/p2-%02d-fateha-amiri.png", shot_n))
        check(a and b and a ~= b, "Arabic renders differently once Amiri is installed")
    end, 1.5)
end

UIManager:scheduleIn(1, runNext)
