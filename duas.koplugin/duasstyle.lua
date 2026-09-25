--[[--
Stylesheet for generated pages.

It is handed to crengine through ReaderStyleTweak (see main.lua), not
embedded in the HTML, so switching a part on or off only re-applies styles:
the document structure stays the same and the reading position is kept.
]]

local Style = {}

-- Parts of a line that can be shown or hidden, in menu order.
Style.PARTS = {
    { key = "ar",    class = "x-ar",    label = "Arabic" },
    { key = "tr",    class = "x-tr",    label = "Transliteration" },
    { key = "en",    class = "x-en",    label = "English" },
    { key = "ru",    class = "x-ru",    label = "Roman Urdu" },
    { key = "ur",    class = "x-ur",    label = "Urdu" },
    { key = "notes", class = "x-notes", label = "Notes and descriptions" },
    { key = "vn",    class = "x-vn",    label = "Verse numbers" },
    { key = "tj",    class = nil,       label = "Waqf signs and tajweed emphasis" },
}

-- Parts that carry the actual text: at least one of them must stay visible.
Style.TEXT_PARTS = { ar = true, tr = true, en = true, ru = true, ur = true }

Style.DEFAULTS = { ar = true, tr = true, en = true, ru = true, ur = true, notes = true, vn = true, tj = true }

local BASE = [[
body { margin: 0; }
h1.pt { font-size: 1.35em; text-align: center; margin: 0.4em 0 0.1em 0; hyphens: none; }
div.pu { font-size: 1.15em; text-align: center; margin: 0 0 0.1em 0; font-family: "Noto Naskh Arabic"; }
p.crumb { font-size: 0.7em; text-align: center; margin: 0 0 1.2em 0; text-indent: 0; }
div.ln { margin: 0 0 0.7em 0; padding: 0 0 0.6em 0; border-bottom: 1px solid #bbbbbb; }
p { text-indent: 0; }
p.vn { font-size: 0.7em; font-weight: bold; text-align: center; margin: 0; }
div.t { text-align: center; font-weight: bold; margin: 0.5em 0 0.3em 0; hyphens: none; }
div.tt { margin: 0; }
p.d { font-size: 0.85em; font-style: italic; margin: 0.2em 0; }
p.lnk { font-weight: bold; margin: 0.3em 0; }
p.ar { font-family: "Amiri", "Noto Naskh Arabic"; font-size: 1.45em; line-height: 1.9; text-align: right; margin: 0.3em 0; hyphens: none; }
div.red p.ar { font-weight: bold; }
span.tj { font-weight: bold; }
sup.ws { font-size: 0.55em; font-weight: normal; }
p.tr { font-style: italic; margin: 0.25em 0; }
p.tl { margin: 0.25em 0; }
p.x-ur, div.x-ur { font-family: "Noto Naskh Arabic"; font-size: 1.1em; line-height: 1.7; text-align: right; }
span.x-ur { font-family: "Noto Naskh Arabic"; }
div.t div.x-ur { text-align: center; }
div.pu { text-align: center; }
b.sn { font-weight: bold; }
p.d a, p.tl a { font-style: normal; }
div.im { text-align: center; margin: 0.3em 0; }
img { max-width: 100%; }
p.nav { font-size: 0.85em; text-align: center; margin: 1em 0; }
ul.kids { margin: 0.5em 0; }
]]

local TAJWEED_OFF = [[
span.tj { font-weight: normal; }
sup.ws { display: none; }
]]

function Style.css(show)
    local css = { BASE }
    for _, part in ipairs(Style.PARTS) do
        if show[part.key] == false then
            if part.class then
                table.insert(css, "." .. part.class .. " { display: none !important; }")
            elseif part.key == "tj" then
                table.insert(css, TAJWEED_OFF)
            end
        end
    end
    return table.concat(css, "\n")
end

return Style
