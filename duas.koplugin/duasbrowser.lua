--[[--
Full-screen list used for browsing the tree, bookmarks, shortcuts and
search results. Levels are loaded from the database one at a time.

Each level is described by a "view": { title = ..., build = function() return items end }.
Items may carry: node (open, or descend if it has children), open_directly,
line (jump target), action (function), header (not selectable).
]]

local Menu = require("ui/widget/menu")
local _ = require("gettext")

local Browser = Menu:extend{
    is_popout = false,
    is_borderless = true,
    covers_fullscreen = true,
    title_bar_fm_style = true,
    single_line = true, -- plain lists; search results switch to 3 lines (view.multiline)
    plugin = nil, -- the Duas plugin instance
}

function Browser:init()
    self.views = self.views or {}
    Menu.init(self)
    if #self.views > 0 then
        self.page = self.views[#self.views].page or 1
        self:refresh(true)
    end
end

function Browser:refresh(keep_page)
    local view = self.views[#self.views]
    local items = view.build()
    if #items == 0 then
        items = { { text = _("Nothing here yet."), header = true, dim = true } }
    end
    -- Measuring multi-line text for every item is the costly part of drawing a
    -- list, so only search results (title + snippet) get it.
    self.single_line = not view.multiline
    self.items_max_lines = view.multiline and 3 or nil
    -- A negative item number keeps self.page (Menu clamps it to the new page count).
    self:switchItemTable(view.title, items, keep_page and -1 or nil)
end

function Browser:push(view)
    self.views[#self.views].page = self.page
    table.insert(self.views, view)
    self:refresh()
end

function Browser:onReturn()
    if #self.views <= 1 then
        self:onClose()
        return true
    end
    table.remove(self.views)
    self.page = self.views[#self.views].page or 1
    self:refresh(true)
    return true
end

function Browser:onMenuSelect(item)
    if item.header then return true end
    if item.action then
        item.action(self)
    elseif item.node then
        self.plugin:onItemSelected(self, item)
    end
    return true
end

function Browser:onMenuHold(item)
    if item.node and (item.node.has_page or item.node.redirect) then
        self.plugin:toggleBookmark(item.node)
        self:refresh(true)
    end
    return true
end

--- Stack of views, so the browser can reopen where the reader left it.
function Browser:getViews()
    if #self.views > 0 then
        self.views[#self.views].page = self.page
    end
    return self.views
end

return Browser
