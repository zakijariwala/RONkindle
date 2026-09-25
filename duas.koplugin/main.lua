--[[--
Duas: browse and read the Path to Supplication content in KOReader.

Pages are small HTML files generated on demand (see duaspages.lua) and read
with KOReader's normal reader. Showing or hiding a language only changes the
stylesheet, so the reading position is kept.

@module koplugin.Duas
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local Pages = require("duaspages")
local Style = require("duasstyle")

-- Loaded on first use, so an idle plugin costs next to nothing.
local lazy = setmetatable({}, { __index = function(t, k)
    local m = require(k)
    rawset(t, k, m)
    return m
end })

local SEARCH_PAGE = 50 -- results per screen of search results
local FONT_FILE = "Amiri-Regular.ttf"

local LANG_LABELS = {
    ar = _("Arabic"), tr = _("Transliteration"), en = _("English"),
    ru = _("Roman Urdu"), ur = _("Urdu"), title = _("Title"),
}

-- Shared by the file manager and reader instances of the plugin.
local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/duas.lua")
local last_views -- browser stack, to reopen where the user left off
local last_query

local Duas = WidgetContainer:extend{
    name = "duas",
    is_doc_only = false,
}

function Duas:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self:isOurDocument() then
        self:hookReader()
    end
end

function Duas:onDispatcherRegisterActions()
    Dispatcher:registerAction("duas_browse", { category = "none", event = "DuasBrowse", title = _("Duas: browse"), general = true })
    Dispatcher:registerAction("duas_quick", { category = "none", event = "DuasQuick", title = _("Duas: Path to Supplication"), general = true })
    Dispatcher:registerAction("duas_search", { category = "none", event = "DuasSearch", title = _("Duas: search"), general = true })
    Dispatcher:registerAction("duas_bookmarks", { category = "none", event = "DuasBookmarks", title = _("Duas: bookmarks"), general = true })
    for __, part in ipairs(Style.PARTS) do
        Dispatcher:registerAction("duas_toggle_" .. part.key, {
            category = "none", event = "DuasToggle", arg = part.key,
            title = T(_("Duas: show/hide %1"), _(part.label)), general = true,
        })
    end
end

-- ─── Helpers ────────────────────────────────────────────────────────────────

function Duas:isOurDocument()
    return self.ui.document ~= nil and Pages:isOurs(self.ui.document.file)
end

--- Node id and part of the page being read, or nil.
function Duas:currentNodeId()
    if self.ui.document then
        return Pages:nodeIdOf(self.ui.document.file)
    end
end

local function name(item)
    return Pages.displayName(item)
end

function Duas:findDB()
    local candidates = {
        DataStorage:getDataDir() .. "/duas/duas.sqlite",
        self.path .. "/duas.sqlite",
    }
    -- Not in the constructor: a nil first entry would end ipairs() at once.
    local custom = settings:readSetting("db_path")
    if custom then table.insert(candidates, 1, custom) end
    for __, path in ipairs(candidates) do
        if lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
end

function Duas:getDB()
    local path = self:findDB()
    if not path then
        UIManager:show(InfoMessage:new{
            text = T(_("Duas database not found.\n\nCopy duas.sqlite to:\n%1"),
                DataStorage:getDataDir() .. "/duas/duas.sqlite"),
        })
        return nil
    end
    local DuasDB = lazy.duasdb
    local ok, err = DuasDB:open(path)
    if not ok then
        logger.warn("Duas: cannot open", path, err)
        UIManager:show(InfoMessage:new{ text = T(_("Cannot open the Duas database:\n%1"), tostring(err)) })
        return nil
    end
    return DuasDB
end

--- Close the database (it is only needed to browse, search or open a page).
function Duas:releaseDB()
    local DuasDB = rawget(lazy, "duasdb")
    if DuasDB then DuasDB:close() end
end

-- ─── Visibility toggles ─────────────────────────────────────────────────────

function Duas:isShown(key)
    return (settings:readSetting("show") or {})[key] ~= false
end

function Duas:showTable()
    local show = {}
    for __, part in ipairs(Style.PARTS) do
        show[part.key] = self:isShown(part.key)
    end
    return show
end

function Duas:setShown(key, value)
    if not value and Style.TEXT_PARTS[key] then
        local others = 0
        for k in pairs(Style.TEXT_PARTS) do
            if k ~= key and self:isShown(k) then others = others + 1 end
        end
        if others == 0 then
            UIManager:show(InfoMessage:new{
                text = _("At least one of Arabic, transliteration or a translation has to stay visible."),
                timeout = 3,
            })
            return false
        end
    end
    local show = settings:readSetting("show") or {}
    show[key] = value
    settings:saveSetting("show", show)
    settings:flush()
    if self:isOurDocument() then
        self.ui:handleEvent(Event:new("ApplyStyleSheet"))
    end
    return true
end

function Duas:onDuasToggle(key)
    local value = not self:isShown(key)
    if self:setShown(key, value) then
        for __, part in ipairs(Style.PARTS) do
            if part.key == key then
                Notification:notify(T(value and _("Showing %1") or _("Hiding %1"), _(part.label)),
                    Notification.SOURCE_ALWAYS_SHOW)
            end
        end
    end
    return true
end

-- ─── Reader integration ─────────────────────────────────────────────────────

function Duas:hookReader()
    -- Our stylesheet rides along with the style tweaks' CSS. Plugins are
    -- initialised before ReaderTypeset reads its settings, so this is in
    -- place for the first render.
    local styletweak = self.ui.styletweak
    if styletweak then
        local orig_getCssText = styletweak.getCssText
        styletweak.getCssText = function(st)
            local css = orig_getCssText(st)
            local ours = Style.css(self:showTable())
            if css and css ~= "" then
                return css .. "\n" .. ours
            end
            return ours
        end
    end

    -- Links between pages: href="duas:<node>", "duas:<node>:<line>" (a verse)
    -- or "duas:<node>/<part>" (another part of a long page).
    local link = self.ui.link
    if link then
        local orig_onGotoLink = link.onGotoLink
        link.onGotoLink = function(l, lnk, ...)
            local url = type(lnk) == "table" and lnk.xpointer
            if type(url) == "string" and url:match("^duas:") then
                local id, sep, n = url:match("^duas:(%d+)([:/]?)(%d*)$")
                if id then
                    n = tonumber(n)
                    self:openNode(tonumber(id), sep == ":" and n or nil, sep == "/" and n or nil)
                    return true
                end
            end
            return orig_onGotoLink(l, lnk, ...)
        end
    end

    -- Showing/hiding a part flips display:none on whole blocks, which crengine
    -- conservatively flags as a possible DOM change and KOReader then offers a
    -- full reload after every toggle. Our pages never need it (verified in the
    -- emulator tests: toggled and freshly loaded pages render identically).
    local rolling = self.ui.rolling
    if rolling then
        rolling.onCheckDomStyleCoherence = function() end
    end
end

--- Open a node: its page (the part holding line, or the given part) if it
--- has one, otherwise the browser at that node.
function Duas:openNode(id, line, part)
    local db = self:getDB()
    if not db then return end
    local node = db:node(id)
    if node and node.redirect then -- an alias of another page
        line = line or node.redirect_line
        node = db:node(node.redirect)
    end
    if not node then
        UIManager:show(InfoMessage:new{ text = _("This entry is not in the database."), timeout = 3 })
        return
    end
    if not node.has_page then
        self:showBrowser(self:viewsFor(node, true))
        return
    end
    if line then
        part = db:partOfLine(node.id, line)
    end
    part = math.max(1, math.min(part or 1, node.parts))
    local path, err = Pages:ensure(db, node, part)
    if not path then
        UIManager:show(InfoMessage:new{ text = T(_("Cannot write the page:\n%1"), tostring(err)) })
        return
    end
    self:closeBrowser()
    self:releaseDB() -- not needed while reading

    local goto_line
    if line then
        goto_line = function(ui)
            local xp = "#l" .. line
            if ui.rolling and ui.document:isXPointerInDocument(xp) then
                ui.rolling:onGotoXPointer(xp, xp)
            end
        end
    end

    if self.ui.document then
        if self.ui.document.file == path then
            if goto_line then goto_line(self.ui) end
            return
        end
        self.ui:switchDocument(path, nil, goto_line)
    else
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path, nil, nil, nil, goto_line)
    end
end

-- ─── Bookmarks ──────────────────────────────────────────────────────────────

function Duas:getBookmarks()
    return settings:readSetting("bookmarks") or {}
end

function Duas:isBookmarked(id)
    for __, b in ipairs(self:getBookmarks()) do
        if b.id == id then return true end
    end
    return false
end

function Duas:toggleBookmark(node, part)
    local bookmarks = self:getBookmarks()
    for i, b in ipairs(bookmarks) do
        if b.id == node.id then
            table.remove(bookmarks, i)
            settings:saveSetting("bookmarks", bookmarks)
            settings:flush()
            Notification:notify(T(_("Bookmark removed: %1"), name(node)), Notification.SOURCE_ALWAYS_SHOW)
            return false
        end
    end
    table.insert(bookmarks, { id = node.id, part = part, title = name(node), time = os.time() })
    settings:saveSetting("bookmarks", bookmarks)
    settings:flush()
    Notification:notify(T(_("Bookmarked: %1"), name(node)), Notification.SOURCE_ALWAYS_SHOW)
    return true
end

-- ─── Browser views ──────────────────────────────────────────────────────────

local function nodeItem(self, node)
    local mandatory
    if node.kids > 0 then
        mandatory = tostring(node.kids)
    elseif self:isBookmarked(node.id) then
        mandatory = "★"
    end
    return { text = name(node), node = node, mandatory = mandatory }
end

function Duas:rootView()
    return {
        title = _("Duas"),
        build = function()
            local db = self:getDB()
            if not db then return {} end
            local items = {
                { text = _("Path to Supplication"), action = function(b) b:push(self:quickView()) end },
                { text = _("Search…"), action = function() self:showSearchDialog() end },
                { text = _("Bookmarks"), mandatory = tostring(#self:getBookmarks()),
                  action = function(b) b:push(self:bookmarksView()) end },
            }
            for __, cat in ipairs(db:categories()) do
                table.insert(items, {
                    text = name(cat),
                    action = function(b) b:push(self:nodeView(cat.id, 0, name(cat))) end,
                })
            end
            return items
        end,
    }
end

function Duas:nodeView(cat, parent, title)
    return {
        title = title,
        build = function()
            local db = self:getDB()
            if not db then return {} end
            local items = {}
            if parent ~= 0 then
                local p = db:node(parent)
                if p and p.has_page then
                    table.insert(items, { text = T(_("Read: %1"), name(p)), node = p, open_directly = true })
                end
            end
            for __, child in ipairs(db:children(cat, parent)) do
                table.insert(items, nodeItem(self, child))
            end
            return items
        end,
    }
end

function Duas:quickView()
    return {
        title = _("Path to Supplication"),
        build = function()
            local db = self:getDB()
            if not db then return {} end
            local items = {}
            for __, group in ipairs(lazy.duasquicklist) do
                table.insert(items, { text = "— " .. _(group.group) .. " —", header = true, dim = true })
                for __, id in ipairs(group.items) do
                    local node = db:node(id)
                    if node then
                        table.insert(items, nodeItem(self, node))
                    end
                end
            end
            return items
        end,
    }
end

function Duas:bookmarksView()
    return {
        title = _("Bookmarks"),
        build = function()
            local db = self:getDB()
            if not db then return {} end
            local items = {}
            local bookmarks = self:getBookmarks()
            for i = #bookmarks, 1, -1 do -- newest first
                local b = bookmarks[i]
                local node = db:node(b.id)
                if node then
                    table.insert(items, {
                        text = name(node), node = node, part = b.part, open_directly = true,
                        mandatory = os.date("%d %b", b.time),
                    })
                end
            end
            return items
        end,
    }
end

--- Views from the root down to a node (its own children when include_self).
function Duas:viewsFor(node, include_self)
    local db = self:getDB()
    local views = { self:rootView() }
    if not db then return views end
    local cat = db:category(node.cat)
    table.insert(views, self:nodeView(node.cat, 0, cat and name(cat) or _("Duas")))
    local chain = db:ancestry(node.id)
    local last = include_self and #chain or #chain - 1
    for i = 1, last do
        table.insert(views, self:nodeView(node.cat, chain[i].id, name(chain[i])))
    end
    return views
end

function Duas:showBrowser(views)
    if not self:getDB() then return end
    self:closeBrowser()
    if not views then
        local current = self:currentNodeId()
        local node = current and lazy.duasdb:node(current)
        views = node and self:viewsFor(node, false) or last_views or { self:rootView() }
    end
    self.browser = lazy.duasbrowser:new{
        plugin = self,
        title = _("Duas"),
        views = views,
        close_callback = function()
            if self.browser then
                last_views = self.browser:getViews()
                self.browser = nil
            end
            self:releaseDB()
        end,
    }
    UIManager:show(self.browser)
end

function Duas:closeBrowser()
    if self.browser then
        local browser = self.browser
        last_views = browser:getViews()
        self.browser = nil
        UIManager:close(browser)
    end
end

function Duas:onItemSelected(browser, item)
    local node = item.node
    if node.kids > 0 and not item.open_directly then
        browser:push(self:nodeView(node.cat, node.id, name(node)))
    else
        self:openNode(node.id, item.line, item.part)
    end
end

-- ─── Search ─────────────────────────────────────────────────────────────────

function Duas:showSearchDialog()
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title = _("Search duas"),
        input = last_query or "",
        input_hint = _("English, Roman Urdu, Urdu or Arabic"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)
                    self:search(query)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- One screen of search results (SEARCH_PAGE hits from offset), with
--- snippets cut only for these. Returns items and whether more follow.
function Duas:searchItems(db, query, offset)
    local Normalize = lazy.duasnormalize
    local match = Normalize.matchExpression(query)
    if not match then return nil end
    local hits, err = db:search(match, SEARCH_PAGE + 1, offset or 0)
    if not hits then
        logger.warn("Duas: search failed", match, err)
        return nil, err
    end
    local more = #hits > SEARCH_PAGE
    if more then table.remove(hits) end
    local tokens = Normalize.tokens(query)
    local nodes, bodies, items = {}, {}, {}
    for __, hit in ipairs(hits) do
        local node = nodes[hit.node] or db:node(hit.node)
        nodes[hit.node] = node
        if node then
            local text = name(node)
            if hit.line then
                local key = hit.node .. "/" .. hit.part
                if bodies[key] == nil then
                    bodies[key] = db:pageBody(hit.node, hit.part) or false
                end
                local snip = Pages.snippet(bodies[key] or nil, hit.line, hit.lang, tokens)
                if snip then text = text .. "\n" .. snip end
            end
            table.insert(items, {
                text = text, node = node, line = hit.line, open_directly = hit.line ~= nil,
                mandatory = LANG_LABELS[hit.lang],
            })
        end
    end
    return items, more
end

function Duas:searchView(query, offset)
    local items, more = self:searchItems(self:getDB(), query, offset)
    if not items then return nil end
    if more then
        table.insert(items, {
            text = _("More results…"),
            action = function(b) b:push(self:searchView(query, offset + SEARCH_PAGE)) end,
        })
    end
    local shown = #items - (more and 1 or 0)
    local title
    if offset == 0 and not more then
        title = T(_("“%1”: %2 results"), query, shown)
    else
        title = T(_("“%1”: results %2–%3"), query, offset + 1, offset + shown)
    end
    return { title = title, multiline = true, build = function() return items end }
end

function Duas:search(query)
    if not self:getDB() then return end
    query = util.trim(query or "")
    if query == "" then return end
    last_query = query
    local view = self:searchView(query, 0)
    if not view then
        UIManager:show(InfoMessage:new{ text = _("Could not search for that. Try other words."), timeout = 3 })
        return
    end
    if self.browser then
        self.browser:push(view)
    else
        self:showBrowser({ self:rootView(), view })
    end
end

-- ─── Font ───────────────────────────────────────────────────────────────────

--- Folder KOReader scans for user fonts: koreader/fonts on e-readers (the
--- install dir), the user font folder on desktop builds with system fonts.
function Duas:fontDir()
    local CanvasContext = require("document/canvascontext")
    if CanvasContext.hasSystemFonts and CanvasContext:hasSystemFonts() then
        local path = require("ui/elements/font_settings"):getPath()
        local user_dir = path and path:match("^[^;]+")
        if user_dir then return user_dir end
    end
    return require("fontlist").fontdir
end

function Duas:fontTarget()
    return self:fontDir() .. "/" .. FONT_FILE
end

function Duas:isFontInstalled()
    return lfs.attributes(self:fontTarget(), "mode") == "file"
end

function Duas:installFont()
    util.makePath(self:fontDir())
    local err = ffiUtil.copyFile(self.path .. "/fonts/" .. FONT_FILE, self:fontTarget())
    if err then
        UIManager:show(InfoMessage:new{ text = T(_("Could not install the font:\n%1"), tostring(err)) })
        return
    end
    UIManager:askForRestart(_("Amiri installed. KOReader needs to restart to use it."))
end

-- ─── Events ─────────────────────────────────────────────────────────────────

function Duas:onDuasBrowse()
    self:showBrowser()
    return true
end

function Duas:onDuasQuick()
    self:showBrowser({ self:rootView(), self:quickView() })
    return true
end

function Duas:onDuasSearch()
    self:showSearchDialog()
    return true
end

function Duas:onDuasBookmarks()
    self:showBrowser({ self:rootView(), self:bookmarksView() })
    return true
end

-- ─── Menu ───────────────────────────────────────────────────────────────────

function Duas:addToMainMenu(menu_items)
    menu_items.duas = {
        text = _("Duas"),
        sorting_hint = self:isOurDocument() and "navi" or "tools",
        sub_item_table_func = function() return self:getMenuItems() end,
    }
end

function Duas:getMenuItems()
    local items = {
        { text = _("Browse"), callback = function() self:onDuasBrowse() end },
        { text = _("Path to Supplication"), callback = function() self:onDuasQuick() end },
        { text = _("Search…"), callback = function() self:onDuasSearch() end },
        { text = _("Bookmarks"), callback = function() self:onDuasBookmarks() end },
    }

    local current, current_part
    if self:isOurDocument() then
        current, current_part = self:currentNodeId()
    end
    if current then
        table.insert(items, {
            text_func = function()
                return self:isBookmarked(current) and _("Remove bookmark") or _("Bookmark this page")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local db = self:getDB()
                local node = db and db:node(current)
                if node then self:toggleBookmark(node, current_part) end
                self:releaseDB()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        })
    end
    items[#items].separator = true

    local show_items = {}
    for __, part in ipairs(Style.PARTS) do
        table.insert(show_items, {
            text = _(part.label),
            checked_func = function() return self:isShown(part.key) end,
            keep_menu_open = true,
            callback = function() self:setShown(part.key, not self:isShown(part.key)) end,
        })
    end
    table.insert(items, { text = _("Show"), sub_item_table = show_items })

    table.insert(items, {
        text = _("Install Amiri Arabic font (optional)"),
        enabled_func = function() return not self:isFontInstalled() end,
        callback = function() self:installFont() end,
    })
    table.insert(items, {
        text = _("About the database"),
        keep_menu_open = true,
        callback = function() self:showInfo() end,
    })
    return items
end

function Duas:showInfo()
    local path = self:findDB()
    local db = path and self:getDB()
    local text
    if db then
        text = T(_("Database: %1\nBuild: %2\nSource: %3\nPages cached in: %4"),
            path, db:meta("build") or "?", db:meta("source") or "?", Pages.dir)
        self:releaseDB()
    else
        text = T(_("No database found. Copy duas.sqlite to:\n%1"),
            DataStorage:getDataDir() .. "/duas/duas.sqlite")
    end
    UIManager:show(InfoMessage:new{ text = text })
end

return Duas
