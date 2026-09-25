--[[--
Generates one small HTML file per dua/surah on demand, from the pre-rendered
body stored in the database. Files are cached until the database changes.
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Pages = {
    dir = DataStorage:getDataDir() .. "/duas/pages",
    checked_build = nil,
}

local function esc(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function writeFile(path, data)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(data)
    f:close()
    return true
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*all")
    f:close()
    return data
end

function Pages.displayName(item)
    return item.en or item.rurdu or item.urdu or "?"
end

local function slug(s)
    s = (s or ""):lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
    if #s > 40 then s = s:sub(1, 40):gsub("-+$", "") end
    return s ~= "" and s or "page"
end

function Pages:isOurs(file)
    return file ~= nil and file:sub(1, #self.dir + 1) == self.dir .. "/"
end

--- Node id and part of one of our page files, or nil.
function Pages:nodeIdOf(file)
    if not self:isOurs(file) then return nil end
    local id, part = file:match("/(%d+)_(%d+)%-[^/]*%.html$")
    return tonumber(id), tonumber(part)
end

function Pages:pathFor(node, part)
    return string.format("%s/%d_%d-%s.html", self.dir, node.id, part or 1, slug(node.en or node.rurdu))
end

--- Drop cached pages when a different database build is in use.
function Pages:checkBuild(build)
    if self.checked_build == build then return end
    util.makePath(self.dir .. "/img")
    local marker = self.dir .. "/.build"
    if readFile(marker) ~= build then
        for _, sub in ipairs({ self.dir, self.dir .. "/img" }) do
            for name in lfs.dir(sub) do
                local path = sub .. "/" .. name
                if name ~= "." and name ~= ".." and lfs.attributes(path, "mode") == "file"
                        and (name:match("%.html$") or name:match("%.png$")) then
                    os.remove(path)
                end
            end
        end
        writeFile(marker, build)
    end
    self.checked_build = build
end

local function link(node, text)
    return string.format('<a href="duas:%d">%s</a>', node.id, esc(text or Pages.displayName(node)))
end

local function partLinks(node, part)
    local links = {}
    if part > 1 then
        table.insert(links, string.format('<a href="duas:%d/%d">‹ Part %d</a>', node.id, part - 1, part - 1))
    end
    table.insert(links, string.format("Part %d of %d", part, node.parts))
    if part < node.parts then
        table.insert(links, string.format('<a href="duas:%d/%d">Part %d ›</a>', node.id, part + 1, part + 1))
    end
    return '<p class="parts">' .. table.concat(links, " · ") .. "</p>"
end

function Pages:render(db, node, part)
    part = part or 1
    local parts = {}
    local function add(s) table.insert(parts, s) end

    local title = Pages.displayName(node)
    add('<?xml version="1.0" encoding="UTF-8"?>\n')
    add('<html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="UTF-8"/>')
    local doc_title = node.parts > 1 and string.format("%s (%d/%d)", title, part, node.parts) or title
    add("<title>" .. esc(doc_title) .. "</title></head><body>")

    local crumbs = {}
    local cat = db:category(node.cat)
    if cat then table.insert(crumbs, esc(Pages.displayName(cat))) end
    local chain = db:ancestry(node.id)
    for i = 1, #chain - 1 do
        table.insert(crumbs, link(chain[i]))
    end

    add('<h1 class="pt">' .. esc(title) .. "</h1>")
    if node.urdu and node.urdu ~= title then
        add('<div class="pu x-ur" dir="rtl" lang="ur">' .. esc(node.urdu) .. "</div>")
    end
    add('<p class="crumb">' .. table.concat(crumbs, " › ") .. "</p>")
    if node.parts > 1 then add(partLinks(node, part)) end

    add(db:pageBody(node.id, part) or "")

    if node.parts > 1 then add(partLinks(node, part)) end
    if part < node.parts then
        add("</body></html>\n")
        return table.concat(parts)
    end
    -- the last part carries the child list and the links to neighbouring pages

    if node.kids > 0 then
        add('<ul class="kids">')
        for _, child in ipairs(db:children(node.cat, node.id)) do
            add("<li>" .. link(child) .. "</li>")
        end
        add("</ul>")
    end

    local prev, nxt = db:neighbours(node)
    if prev or nxt then
        local nav = {}
        if prev then table.insert(nav, link(prev, "‹ " .. Pages.displayName(prev))) end
        if nxt then table.insert(nav, link(nxt, Pages.displayName(nxt) .. " ›")) end
        add('<p class="nav">' .. table.concat(nav, " · ") .. "</p>")
    end

    add("</body></html>\n")
    return table.concat(parts)
end

--- Make sure the page file (and its images) exist; returns the file path.
function Pages:ensure(db, node, part)
    self:checkBuild(db:meta("build") or "?")
    local path = self:pathFor(node, part)
    if lfs.attributes(path, "mode") == "file" then
        return path
    end
    for _, img in ipairs(db:images(node.id)) do
        local img_path = self.dir .. "/img/" .. img[1]
        if lfs.attributes(img_path, "mode") ~= "file" then
            writeFile(img_path, img[2])
        end
    end
    local ok, err = writeFile(path, self:render(db, node, part))
    if not ok then return nil, err end
    return path
end

--- Plain text of one language part of a line, cut around the first matching token.
function Pages.snippet(body, line, lang, tokens, max_len)
    max_len = max_len or 110
    if not body or not line then return nil end
    local start = body:find('id="l' .. line .. '"', 1, true)
    if not start then return nil end
    local stop = body:find('<div class="ln', start + 1, true) or #body
    local chunk = body:sub(start, stop)
    local texts = {}
    for inner in chunk:gmatch('class="[^"]*x%-' .. lang .. '[^"]*"[^>]*>(.-)</[pd][i]?[v]?>') do
        table.insert(texts, inner)
    end
    if #texts == 0 then return nil end
    local text = table.concat(texts, " · ")
    text = util.htmlEntitiesToUtf8(text:gsub("<sup[^>]*>.-</sup>", ""):gsub("<[^>]+>", ""))
    text = text:gsub("%s+", " ")
    if #text <= max_len then return text end

    -- Centre on the first token found (ASCII case-insensitive), else keep the start.
    local pos = 1
    local lower = text:lower()
    for _, tok in ipairs(tokens or {}) do
        local p = lower:find(tok:lower(), 1, true)
        if p then
            pos = math.max(1, p - math.floor(max_len / 3))
            break
        end
    end
    -- Don't start or end in the middle of a UTF-8 sequence.
    while pos > 1 and text:byte(pos) and text:byte(pos) >= 0x80 and text:byte(pos) < 0xC0 do
        pos = pos - 1
    end
    local last = math.min(#text, pos + max_len)
    while last < #text and text:byte(last + 1) >= 0x80 and text:byte(last + 1) < 0xC0 do
        last = last + 1
    end
    return (pos > 1 and "…" or "") .. text:sub(pos, last) .. (last < #text and "…" or "")
end

return Pages
