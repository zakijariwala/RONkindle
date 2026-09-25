--[[--
Read-only access to duas.sqlite (built by scripts/build_kindle_db.py).
]]

local ffi = require("ffi")
local SQ3 = require("lua-ljsqlite3/init")
local zlib = require("ffi/zlib")

local DuasDB = {
    SCHEMA = 4, -- must match SCHEMA_VERSION in scripts/build_kindle_db.py
    conn = nil,
    path = nil,
}

-- ljsqlite3 returns integers as int64 cdata and blobs as { ptr, size }
-- pointing into SQLite's memory: copy them into plain Lua values right away.
local function plain(v)
    local t = type(v)
    if t == "cdata" then
        return tonumber(v)
    elseif t == "table" and v[1] ~= nil and v[2] ~= nil then
        return ffi.string(v[1], tonumber(v[2]))
    end
    return v
end

function DuasDB:open(path)
    if self.conn and self.path == path then return true end
    self:close()
    local ok, conn = pcall(SQ3.open, path, "ro")
    if not ok then
        return false, conn
    end
    self.conn = conn
    self.path = path
    -- Keep SQLite's own memory small: a 256 KB page cache, no memory mapping.
    pcall(conn.exec, conn, "PRAGMA cache_size = -256; PRAGMA mmap_size = 0; PRAGMA temp_store = FILE;")
    local schema = self:meta("schema")
    if not schema then
        self:close()
        return false, "not a Duas database (missing meta table)"
    end
    if tonumber(schema) ~= self.SCHEMA then
        self:close()
        return false, string.format("duas.sqlite has format %s but this plugin needs format %d: rebuild it with scripts/build_kindle_db.py",
            schema, self.SCHEMA)
    end
    return true
end

function DuasDB:close()
    if self.conn then
        pcall(self.conn.close, self.conn)
    end
    self.conn = nil
    self.path = nil
end

--- Run a query and return an array of rows, each row an array of plain values.
function DuasDB:rows(sql, ...)
    local stmt = self.conn:prepare(sql)
    if select("#", ...) > 0 then
        stmt:bind(...)
    end
    -- (a statement per call: nothing is cached between calls)
    local out = {}
    while true do
        local row = stmt:step()
        if not row then break end
        -- NULL columns are holes in row, so walk it with pairs().
        local r = {}
        for i, v in pairs(row) do
            r[i] = plain(v)
        end
        table.insert(out, r)
    end
    stmt:close()
    return out
end

function DuasDB:meta(key)
    local ok, rows = pcall(self.rows, self, "SELECT value FROM meta WHERE key = ?", key)
    return ok and rows[1] and rows[1][1] or nil
end

local function toCategory(r)
    return { id = r[1], en = r[2], rurdu = r[3], urdu = r[4] }
end

function DuasDB:categories()
    local list = {}
    for _, r in ipairs(self:rows("SELECT id, en, rurdu, urdu FROM categories ORDER BY num")) do
        table.insert(list, toCategory(r))
    end
    return list
end

function DuasDB:category(id)
    local r = self:rows("SELECT id, en, rurdu, urdu FROM categories WHERE id = ?", id)[1]
    return r and toCategory(r)
end

local NODE_COLS = "id, parent, cat, en, rurdu, urdu, kids, has_page, redirect, redirect_line, listed, parts"

local function toNode(r)
    return {
        id = r[1], parent = r[2], cat = r[3], en = r[4], rurdu = r[5], urdu = r[6],
        kids = r[7] or 0, has_page = (r[8] or 0) == 1,
        redirect = r[9], redirect_line = r[10], -- alias entries open another page
        listed = (r[11] or 0) == 1, -- hidden entries open from links and search only
        parts = math.max(1, r[12] or 1), -- long pages are split into parts
    }
end

--- Listed children of a node (parent = 0 means the top level of a category).
function DuasDB:children(cat, parent)
    local list = {}
    for _, r in ipairs(self:rows("SELECT " .. NODE_COLS .. " FROM nodes WHERE cat = ? AND parent = ? AND listed = 1 ORDER BY num",
            cat, parent or 0)) do
        table.insert(list, toNode(r))
    end
    return list
end

function DuasDB:node(id)
    local r = self:rows("SELECT " .. NODE_COLS .. " FROM nodes WHERE id = ?", id)[1]
    return r and toNode(r)
end

--- Chain of nodes from the category top level down to (and including) id.
function DuasDB:ancestry(id)
    local chain = {}
    local node = self:node(id)
    local guard = 0
    while node and guard < 50 do
        table.insert(chain, 1, node)
        if node.parent == 0 then break end
        node = self:node(node.parent)
        guard = guard + 1
    end
    return chain
end

--- Previous and next siblings that have a page, for in-page navigation.
function DuasDB:neighbours(node)
    if not node.listed then return nil, nil end
    local prev, nxt, seen
    for _, n in ipairs(self:children(node.cat, node.parent)) do
        if n.id == node.id then
            seen = true
        elseif n.has_page then
            if seen then
                nxt = n
                break
            end
            prev = n
        end
    end
    return prev, nxt
end

function DuasDB:pageBody(id, part)
    local r = self:rows("SELECT size, body FROM pages WHERE node = ? AND part = ?", id, part or 1)[1]
    if not r then return nil end
    return zlib.zlib_uncompress(r[2], r[1])
end

--- Part of a (split) page holding a line; 1 when the page isn't split.
function DuasDB:partOfLine(id, line)
    local r = self:rows("SELECT part FROM anchors WHERE node = ? AND line = ?", id, line)[1]
    return r and r[1] or 1
end

function DuasDB:images(id)
    return self:rows("SELECT name, data FROM images WHERE node = ?", id)
end

--- Full-text search, one hit per line (or page title) in book order, with
--- the first language that matched. Returns { node=, line=, lang=, part= }.
function DuasDB:search(match, limit, offset)
    local hits = {}
    -- SQLite returns the bare columns from the row holding min(rowid).
    local ok, rows = pcall(self.rows, self, [[
        SELECT t.node, t.line, t.lang, t.part, min(fts.rowid) AS first
        FROM fts JOIN texts t ON t.id = fts.rowid
        WHERE fts MATCH ? GROUP BY t.node, ifnull(t.line, -1)
        ORDER BY first LIMIT ? OFFSET ?]], match, limit, offset or 0)
    if not ok then
        return nil, rows
    end
    for _, r in ipairs(rows) do
        table.insert(hits, { node = r[1], line = r[2], lang = r[3], part = r[4] or 1 })
    end
    return hits
end

return DuasDB
