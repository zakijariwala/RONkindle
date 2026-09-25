--[[--
Search text normalisation.

Must stay in step with normalize() in scripts/build_kindle_db.py: the index
is built from normalised text, so queries have to be normalised the same way.
Harakat and Qur'anic marks are dropped (the FTS tokenizer would otherwise
split words on them), letter variants are unified and apostrophes removed.
]]

local Normalize = {}

local DROP_RANGES = {
    { 0x0610, 0x061A }, { 0x064B, 0x065F }, { 0x0670, 0x0670 }, { 0x06D6, 0x06ED },
    { 0x08D3, 0x08FF }, { 0x0640, 0x0640 }, { 0x200B, 0x200F }, { 0xFEFF, 0xFEFF },
}
local DROP = {
    [0x27] = true, [0x2019] = true, [0x2018] = true, [0x60] = true, [0x2BC] = true, [0xB4] = true,
}

local MAP = {
    [0x0623] = 0x0627, [0x0625] = 0x0627, [0x0622] = 0x0627, [0x0671] = 0x0627, -- alef forms → ا
    [0x0649] = 0x06CC, [0x064A] = 0x06CC, [0x0626] = 0x06CC,                    -- yeh forms → ی
    [0x0643] = 0x06A9,                                                           -- ك → ک
    [0x0629] = 0x0647, [0x06C1] = 0x0647, [0x06C2] = 0x0647, [0x06BE] = 0x0647, [0x06C3] = 0x0647, -- heh forms → ه
    [0x0624] = 0x0648,                                                           -- ؤ → و
}

-- Only used for queries: punctuation the tokenizer treats as a word break.
local QUERY_SEPARATORS = {
    [0x060C] = true, [0x061B] = true, [0x061F] = true, [0x06D4] = true, [0x00AB] = true,
    [0x00BB] = true, [0x2026] = true, [0x201C] = true, [0x201D] = true, [0x201E] = true,
}

local function isDropped(cp)
    if DROP[cp] then return true end
    for _, r in ipairs(DROP_RANGES) do
        if cp >= r[1] and cp <= r[2] then return true end
    end
    return false
end

local function decode(ch)
    local b1 = ch:byte(1)
    if b1 < 0x80 then return b1 end
    if b1 < 0xE0 then return (b1 % 0x20) * 0x40 + ch:byte(2) % 0x40 end
    if b1 < 0xF0 then return ((b1 % 0x10) * 0x40 + ch:byte(2) % 0x40) * 0x40 + ch:byte(3) % 0x40 end
    return (((b1 % 0x08) * 0x40 + ch:byte(2) % 0x40) * 0x40 + ch:byte(3) % 0x40) * 0x40 + ch:byte(4) % 0x40
end

local function encode(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

function Normalize.text(s, for_query)
    local out = {}
    for ch in s:gmatch(UTF8_CHAR) do
        local cp = decode(ch)
        if for_query and QUERY_SEPARATORS[cp] then
            table.insert(out, " ")
        elseif not isDropped(cp) then
            local mapped = MAP[cp]
            table.insert(out, mapped and encode(mapped) or ch)
        end
    end
    return table.concat(out)
end

--- Split a user query into tokens, as the unicode61 tokenizer would.
function Normalize.tokens(query)
    local s = Normalize.text(query, true)
    local tokens = {}
    -- ASCII punctuation and spaces separate tokens; UTF-8 bytes (≥ 0x80) are kept.
    for tok in s:gmatch("[%w\128-\255]+") do
        table.insert(tokens, tok)
    end
    return tokens
end

--- Build an FTS5 MATCH expression: every token must appear, as a prefix.
function Normalize.matchExpression(query)
    local parts = {}
    for _, tok in ipairs(Normalize.tokens(query)) do
        table.insert(parts, '"' .. tok .. '"*')
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

return Normalize
