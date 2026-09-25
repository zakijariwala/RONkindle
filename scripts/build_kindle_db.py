#!/usr/bin/env python3
"""
build_kindle_db.py — builds the database used by the Duas KOReader plugin.
Usage: python3 scripts/build_kindle_db.py path/to/ron.db duas.sqlite [--include-hidden]

Subindex rows marked IsVisible = 0 are hidden as in the source app: they are
not listed when browsing but are still pages that links and search open (631
links on visible pages lead to them). --include-hidden lists them as well.
Hidden categories are never listed; their entries are likewise link targets.

Reads ron.db and writes a slimmed, pre-rendered SQLite file:
  categories   visible categories
  nodes        the subindex tree (display names already resolved)
  pages        pre-rendered, zlib-compressed HTML per subindex that has lines,
               split into parts of about PART_BYTES (long surahs, long duas)
  anchors      which part holds each line, for pages with several parts
  images       decoded PNGs for the image-based lines
  texts + fts  (node, line, language) per searchable text plus its FTS5 index;
               result snippets are cut from the page itself on the device
  meta         schema version and build id

Every language part of a line carries its own CSS class (x-ar, x-tr, x-en,
x-ru, x-ur, x-notes, x-vn) so the plugin can show/hide them with a stylesheet
without touching the document structure.
"""

import argparse
import base64
import html
import os
import re
import sqlite3
import sys
import time
import zlib

SCHEMA_VERSION = 4

# Long pages are split into parts of about this many bytes of HTML: every open
# and every show/hide lays out a whole file, so cost grows with page length.
PART_BYTES = 60_000

# language key → CSS class suffix used by the plugin
LANG_CLASS = {"en": "en", "rurdu": "ru", "urdu": "ur"}
RTL_LANGS = {"urdu"}

# A trailing verse reference such as "(36:1)" or "(2:255-257)" in a <Name> link.
VERSE_REF = re.compile(r"\s*\(\s*\d+\s*:\s*\d+(?:\s*[-–]\s*\d+)?\s*\)\s*$")

# ─── Search normalisation (mirrored in duas.koplugin/duasnormalize.lua) ──────────

_DROP = set()
for lo, hi in [(0x0610, 0x061A), (0x064B, 0x065F), (0x0670, 0x0670), (0x06D6, 0x06ED),
               (0x08D3, 0x08FF), (0x0640, 0x0640), (0x200B, 0x200F), (0xFEFF, 0xFEFF)]:
    _DROP.update(range(lo, hi + 1))
_DROP.update(ord(c) for c in "'’‘`ʼ´")

_MAP = {
    "أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا",
    "ى": "ی", "ي": "ی", "ئ": "ی",
    "ك": "ک",
    "ة": "ه", "ہ": "ه", "ۂ": "ه", "ھ": "ه", "ۃ": "ه",
    "ؤ": "و",
}


def normalize(text):
    out = []
    for ch in text:
        if ord(ch) in _DROP:
            continue
        out.append(_MAP.get(ch, ch))
    return "".join(out)


# ─── Reading lines ───────────────────────────────────────────────────────────

LANG_PREFIX = {"en": "English", "rurdu": "RUrdu", "urdu": "Urdu"}


def nullstrip(v):
    """None for empty/whitespace values, else the stripped string."""
    if v is None:
        return None
    s = str(v).strip()
    return s or None


def arabic_segment_count(cur):
    cur.execute("PRAGMA table_info(lines)")
    nums = [int(m.group(1)) for r in cur.fetchall() if (m := re.fullmatch(r"ArabicText(\d+)", r[1]))]
    return max(nums) if nums else 0


def build_line(row, n_segments):
    """One lines row (dict) → the structure the renderer uses."""
    line = {"id": row["Id"], "seq": row.get("Sequence")}
    images = {k: nullstrip(row.get(f"{p}Image")) for k, p in LANG_PREFIX.items()}
    if any(images.values()):
        line["type"] = "image"
        line["images"] = {k: v for k, v in images.items() if v}
        return line
    line["type"] = "text"
    for key, suffix in (("title", "Title"), ("desc", "Description")):
        vals = {k: nullstrip(row.get(f"{p}{suffix}")) for k, p in LANG_PREFIX.items()}
        if any(vals.values()):
            line[key] = vals
    trans = {k: nullstrip(row.get(p)) for k, p in LANG_PREFIX.items()}
    if any(trans.values()):
        line["trans"] = trans
    segs = []
    for i in range(1, n_segments + 1):
        text = nullstrip(row.get(f"ArabicText{i}"))
        if not text:
            continue
        seg = {"text": text}
        for colour in ("Green", "Red", "Blue"):
            sign = nullstrip(row.get(f"Arabic{colour}Sign{i}"))
            if sign:
                seg["sign"], seg["colour"] = sign, colour[0].lower()
                break
        segs.append(seg)
    if segs:
        line["arabic"] = segs
    if nullstrip(row.get("RArabic")):
        line["rarabic"] = nullstrip(row["RArabic"])
    if row.get("IsRed"):
        line["isRed"] = True
    if row.get("MinimizeDescriptionLine"):
        line["minimizeDesc"] = True
    return line


def decode_image(value):
    """Images are stored as base64, with or without a data: URI prefix."""
    if value.startswith("data:"):
        value = value.split(",", 1)[1]
    return base64.b64decode(value)


# ─── HTML rendering ──────────────────────────────────────────────────────────

def esc(s):
    return html.escape(s, quote=False)


def lang_div(cls, text, lang_key, tag="div"):
    attrs = f' class="{cls} x-{LANG_CLASS[lang_key]}"'
    if lang_key in RTL_LANGS:
        attrs += ' dir="rtl" lang="ur"'
    return f"<{tag}{attrs}>{esc(text)}</{tag}>"


def dedupe_langs(d):
    """Drop the Roman Urdu variant when it is identical to the English one."""
    d = dict(d or {})
    if d.get("rurdu") and d.get("rurdu") == d.get("en"):
        d["rurdu"] = None
    return d


def render_arabic(segs):
    parts = []
    for seg in segs:
        if seg.get("sign"):
            c = seg["colour"]
            parts.append(f'<span class="tj tj-{c}">{esc(seg["text"])}'
                         f'<sup class="ws ws-{c}">{esc(seg["sign"])}</sup></span>')
        else:
            parts.append(esc(seg["text"]))
    return '<p class="ar x-ar" dir="rtl" lang="ar">' + " ".join(parts) + "</p>"


LINK = re.compile(r"<([^<>]+)>")
WHOLE_LINK = re.compile(r"^<([^<>]+)>\W*$")
VERSE_IN_REF = re.compile(r"\(\s*(\d+)\s*:\s*(\d+)")


class Links:
    """Resolves <Name> references in descriptions to (node id, line id or None).

    Names are matched case-insensitively against subindex names; a trailing
    verse reference such as "(3:18-19)" is stripped for the lookup and, when
    the target page numbers its verses, turned into a jump to that verse.
    Alias entries (pages that only point elsewhere) are followed.
    """

    def __init__(self, title_index, verse_lines, redirects=None):
        self.title_index = title_index    # lower-case name → node id
        self.verse_lines = verse_lines    # node id → {verse number: line id}
        self.redirects = redirects or {}  # alias node id → (node id, line id)

    def resolve(self, name):
        key = " ".join(name.split()).lower()
        target = self.title_index.get(key)
        if target is None:
            target = self.title_index.get(VERSE_REF.sub("", key).strip())
        if target is None:
            return None
        line = None
        m = VERSE_IN_REF.search(name)
        if m:
            line = self.verse_lines.get(target, {}).get(int(m.group(2)))
        return self.follow(target, line)

    def follow(self, target, line=None):
        seen = set()
        while target in self.redirects and target not in seen:
            seen.add(target)
            target, redirect_line = self.redirects[target]
            line = line or redirect_line
        return target, line


def href(res):
    return f"duas:{res[0]}:{res[1]}" if res[1] else f"duas:{res[0]}"


def link_targets(text, links):
    return [links.resolve(m.group(1)) for m in LINK.finditer(text or "")]


def render_linked(text, links, node_id, fallback):
    """Escape text, turning <Name> into links. fallback: targets resolved from
    the English description, used by position when this language's own names
    don't resolve (Urdu names are often spelled differently)."""
    out, pos = [], 0
    for i, m in enumerate(LINK.finditer(text)):
        out.append(esc(text[pos:m.start()]))
        name = m.group(1).strip()
        res = links.resolve(name)
        if res is None and i < len(fallback):
            res = fallback[i]
        if res and (res[0] != node_id or res[1]):
            out.append(f'<a href="{href(res)}">{esc(name)}</a>')
        else:
            out.append(esc(name))
        pos = m.end()
    out.append(esc(text[pos:]))
    return "".join(out)


def strip_links(text):
    return LINK.sub(lambda m: m.group(1), text)


def has_link(line):
    return any(LINK.search(v or "") for v in (line.get("desc") or {}).values())


def shows_desc(line):
    """Descriptions the app collapses stay hidden, unless they carry links."""
    desc = line.get("desc") or {}
    if not any(desc.values()):
        return False
    return not line.get("minimizeDesc") or has_link(line)


def has_content(line):
    """Anything besides descriptions: Arabic, translation, heading or image."""
    if line["type"] == "image":
        return True
    title = line.get("title") or {}
    trans = line.get("trans") or {}
    return bool(line.get("arabic") or line.get("rarabic") or any(trans.values()) or any(title.values()))


def is_visible(line):
    return has_content(line) or shows_desc(line)


def step_prefix(line):
    return f'<b class="sn">{line["seq"]}.</b> ' if line.get("seq") and not line.get("arabic") else ""


def render_line(line, verse, anchor, links, node_id, images):
    anchor_attr = f' id="l{line["id"]}"' if anchor else ""
    if line["type"] == "image":
        out = [f'<div class="ln img"{anchor_attr}>']
        seen = {}
        for lang in ("en", "rurdu", "urdu"):
            uri = line["images"].get(lang)
            if not uri:
                continue
            data = decode_image(uri)
            classes = [f"x-{LANG_CLASS[lang]}"]
            if data in seen:  # same picture for several languages → one <img>
                seen[data].extend(classes)
                continue
            seen[data] = classes
        for i, (data, classes) in enumerate(seen.items()):
            name = f"{line['id']}_{i}.png"
            images.append((name, node_id, data))
            out.append(f'<div class="im {" ".join(classes)}"><img src="img/{name}" alt=""/></div>')
        out.append("</div>")
        return "".join(out)

    cls = "ln red" if line.get("isRed") else "ln"
    out = [f'<div class="{cls}"{anchor_attr}>']
    if verse:
        out.append(f'<p class="vn x-vn">{verse}</p>')
    prefix = step_prefix(line)

    title = dedupe_langs(line.get("title"))
    if any(title.values()):
        out.append('<div class="t">')
        for lang in ("en", "rurdu", "urdu"):
            if title.get(lang):
                out.append(lang_div("tt", title[lang], lang))
        out.append("</div>")

    desc = line.get("desc") or {}
    if shows_desc(line):
        en_targets = link_targets(desc.get("en"), links)
        whole = WHOLE_LINK.match((desc.get("en") or desc.get("rurdu") or "").strip())
        if whole and en_targets and en_targets[0]:
            # A description that is only a link: show it as a navigation line.
            label = esc(whole.group(1).strip())
            urdu = WHOLE_LINK.match((desc.get("urdu") or "").strip())
            urdu_html = (f' <span class="x-ur" dir="rtl" lang="ur">{esc(urdu.group(1).strip())}</span>'
                         if urdu else "")
            res = en_targets[0]
            lead = prefix or "→ "
            if res[0] != node_id or res[1]:
                out.append(f'<p class="lnk">{lead}<a href="{href(res)}">{label}</a>{urdu_html}</p>')
            else:
                out.append(f'<p class="lnk">{lead}{label}{urdu_html}</p>')
        else:
            desc = dedupe_langs(desc)
            for lang in ("en", "rurdu", "urdu"):
                if desc.get(lang):
                    attrs = f' class="d x-notes x-{LANG_CLASS[lang]}"'
                    if lang in RTL_LANGS:
                        attrs += ' dir="rtl" lang="ur"'
                    body = render_linked(desc[lang], links, node_id, en_targets)
                    out.append(f"<p{attrs}>{prefix}{body}</p>")

    if line.get("arabic"):
        out.append(render_arabic(line["arabic"]))
    if line.get("rarabic"):
        out.append(f'<p class="tr x-tr">{esc(line["rarabic"])}</p>')

    trans = line.get("trans") or {}
    en_targets = link_targets(trans.get("en"), links)
    for lang in ("en", "rurdu", "urdu"):
        if trans.get(lang):
            attrs = f' class="tl x-{LANG_CLASS[lang]}"'
            if lang in RTL_LANGS:
                attrs += ' dir="rtl" lang="ur"'
            out.append(f"<p{attrs}>{render_linked(trans[lang], links, node_id, en_targets)}</p>")
    out.append("</div>")
    return "".join(out)


def line_texts(line):
    """(lang, raw text) pairs indexed for search: what the page shows."""
    if line["type"] != "text":
        return []
    res = []
    if line.get("arabic"):
        res.append(("ar", " ".join(s["text"] for s in line["arabic"])))
    if line.get("rarabic"):
        res.append(("tr", line["rarabic"]))
    for lang in ("en", "rurdu", "urdu"):
        bits = []
        for key in ("title", "desc", "trans"):
            if key == "desc" and not shows_desc(line):
                continue
            v = (line.get(key) or {}).get(lang)
            if v:
                bits.append(strip_links(v))
        if bits:
            res.append((LANG_CLASS[lang], " ".join(bits)))
    return res


def verse_numbers(lines):
    """Verse badge per line: the source's own numbers where the page has them
    on its Arabic lines (the Qur'an), otherwise a running count of every
    Arabic line that is not a heading."""
    uses_seq = any(ln.get("arabic") and ln.get("seq") for ln in lines)
    numbers, count = [], 0
    for ln in lines:
        n = None
        if ln["type"] == "text" and ln.get("arabic"):
            if uses_seq:
                n = ln.get("seq")
            elif not is_heading(ln):
                count += 1
                n = count
        numbers.append(n)
    return numbers


# ─── Tree ────────────────────────────────────────────────────────────────────

def is_heading(line):
    return bool(any((line.get("title") or {}).values()))


def display_name(r, prefix):
    """app.js renderNavItem(): prefer the hyperlink name over the index title."""
    hl = nullstrip(r[f"Hyperlink{prefix}Name"])
    if hl and hl != "0":
        return hl
    t = nullstrip(r[f"{prefix}IndexName"])
    return t if t and t != "0" else None


def load_tree(cur, include_hidden=False):
    """All categories and subindex rows. Returns (visible categories, all
    categories, nodes). A node is "listed" (shown when browsing) unless its row
    is hidden (IsVisible = 0); hidden rows are still pages that links and
    search lead to, as in the source app. Nodes of hidden categories are only
    reachable that way too, since their category is never listed."""
    cur.execute("SELECT Id, Number, EnglishName, RUrduName, UrduName, IsVisible FROM categories ORDER BY Number")
    all_categories = [dict(r) for r in cur.fetchall()]
    categories = [c for c in all_categories if c["IsVisible"] == 1]
    cat_ids = {c["Id"] for c in all_categories}

    cur.execute("""
        SELECT Id, ParentId, Level, Number, CategoryId, IsVisible,
               EnglishIndexName, RUrduIndexName, UrduIndexName,
               EnglishName, RUrduName, UrduName,
               HyperlinkEnglishName, HyperlinkRUrduName, HyperlinkUrduName
        FROM subindex ORDER BY Level, Number
    """)
    rows = {r["Id"]: r for r in cur.fetchall()}

    # Level-0 rows hang off a category, deeper rows off another subindex row.
    parent = {}
    for nid, r in rows.items():
        if r["Level"] == 0 and r["ParentId"] in cat_ids:
            parent[nid] = 0
        elif r["ParentId"] in rows:
            parent[nid] = r["ParentId"]

    def root_cat(nid, depth=0):
        if depth > 50 or nid not in parent:
            return None
        if parent[nid] == 0:
            return rows[nid]["ParentId"]
        return root_cat(parent[nid], depth + 1)

    nodes = {}
    for nid, r in rows.items():
        cat = root_cat(nid)
        if cat not in cat_ids:
            continue
        nodes[nid] = {
            "id": nid,
            "parent": parent[nid],
            "cat": cat,
            "num": r["Number"],
            "listed": 1 if (r["IsVisible"] != 0 or include_hidden) else 0,
            "en": display_name(r, "English"),
            "rurdu": display_name(r, "RUrdu"),
            "urdu": display_name(r, "Urdu"),
            # raw titles too, for resolving <Name> links like the app does
            "keys": [v for v in (r["EnglishIndexName"], r["RUrduIndexName"], r["UrduIndexName"],
                                 r["EnglishName"], r["RUrduName"], r["UrduName"],
                                 r["HyperlinkEnglishName"], r["HyperlinkRUrduName"],
                                 r["HyperlinkUrduName"]) if v and str(v).strip() not in ("", "0")],
        }
    return categories, all_categories, nodes


# ─── Main ────────────────────────────────────────────────────────────────────

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE categories (id INTEGER PRIMARY KEY, num INTEGER, en TEXT, rurdu TEXT, urdu TEXT);
CREATE TABLE nodes (
    id INTEGER PRIMARY KEY, parent INTEGER, cat INTEGER, num INTEGER,
    en TEXT, rurdu TEXT, urdu TEXT, kids INTEGER, has_page INTEGER,
    redirect INTEGER, redirect_line INTEGER, listed INTEGER, parts INTEGER);
CREATE INDEX nodes_parent ON nodes(cat, parent, listed, num);
CREATE TABLE pages (node INTEGER, part INTEGER, size INTEGER, body BLOB, PRIMARY KEY (node, part));
CREATE TABLE anchors (node INTEGER, line INTEGER, part INTEGER, PRIMARY KEY (node, line));
CREATE TABLE images (name TEXT PRIMARY KEY, node INTEGER, data BLOB);
CREATE INDEX images_node ON images(node);
CREATE TABLE texts (id INTEGER PRIMARY KEY, node INTEGER, line INTEGER, lang TEXT, part INTEGER);
CREATE VIRTUAL TABLE fts USING fts5(body, content='', detail=none, tokenize='unicode61 remove_diacritics 2');
"""


def split_parts(blocks):
    """Group rendered line blocks [(html, is_heading)] into parts of about
    PART_BYTES, never ending a part on a heading (it goes with what follows)."""
    total = sum(len(h.encode("utf-8")) for h, _ in blocks)
    n = max(1, -(-total // PART_BYTES))
    if n == 1:
        return [blocks]
    target = total / n
    parts, acc = [[]], 0
    for i, (h, head) in enumerate(blocks):
        size = len(h.encode("utf-8"))
        prev_heading = parts[-1] and parts[-1][-1][1]
        if parts[-1] and acc + size / 2 > target and not prev_heading and len(parts) < n:
            parts.append([])
            acc = 0
        parts[-1].append((h, head))
        acc += size
    return parts


def add_text(out, node, line, lang, raw, part=1):
    rowid = out.execute("INSERT INTO texts (node, line, lang, part) VALUES (?,?,?,?)",
                        (node, line, lang, part)).lastrowid
    out.execute("INSERT INTO fts (rowid, body) VALUES (?,?)", (rowid, normalize(raw)))


def build(src, dst, include_hidden=False):
    if os.path.exists(dst):
        os.remove(dst)
    con = sqlite3.connect(src)
    con.row_factory = sqlite3.Row
    cur = con.cursor()

    print("▶ Reading tree …")
    categories, all_categories, nodes = load_tree(cur, include_hidden)
    kids = {}  # listed children per node, i.e. what browsing shows
    for n in nodes.values():
        if n["listed"]:
            key = n["parent"] if n["parent"] else ("cat", n["cat"])
            kids[key] = kids.get(key, 0) + 1
    print(f"   {len(categories)} categories, {len(nodes)} nodes "
          f"({sum(1 for n in nodes.values() if not n['listed'])} hidden: reachable by links and search)")

    out = sqlite3.connect(dst)
    out.executescript(SCHEMA)
    out.executemany("INSERT INTO categories VALUES (?,?,?,?,?)",
                    [(c["Id"], c["Number"], nullstrip(c["EnglishName"]), nullstrip(c["RUrduName"]),
                      nullstrip(c["UrduName"])) for c in categories])

    print("▶ Rendering pages …")
    n_segments = arabic_segment_count(cur)
    print(f"   {n_segments} Arabic segment columns")
    cur.execute("""
        SELECT l.*, lm.SubindexId AS _sid FROM linesmetadata lm JOIN lines l ON l.Id = lm.LinesId
        ORDER BY lm.SubindexId, lm.Number
    """)

    by_node = {}
    for r in cur:
        sid = r["_sid"]
        if sid in nodes:
            by_node.setdefault(sid, []).append(build_line(dict(r), n_segments))
    for nid in by_node:
        by_node[nid] = [ln for ln in by_node[nid] if is_visible(ln)]

    # Link targets. Pages with real content win over alias entries of the same
    # name (an alias only carries a "<Name>" pointer to the real page), and
    # entries with nothing to open are never targets.
    title_index = {}
    ranked = sorted(nodes.values(), key=lambda n: any(has_content(ln) for ln in by_node.get(n["id"], [])))
    for n in ranked:
        if by_node.get(n["id"]) or kids.get(n["id"]):
            for k in n["keys"]:
                title_index[" ".join(str(k).split()).lower()] = n["id"]
    verse_lines = {}
    for nid, lines in by_node.items():
        for ln in lines:
            if ln.get("arabic") and ln.get("seq"):
                verse_lines.setdefault(nid, {}).setdefault(ln["seq"], ln["id"])
    links = Links(title_index, verse_lines)

    # Aliases: an entry whose only line is a "<Name>" pointer opens its target.
    redirects = {}
    for nid, lines in by_node.items():
        if len(lines) == 1 and not has_content(lines[0]):
            desc = lines[0].get("desc") or {}
            m = WHOLE_LINK.match((desc.get("en") or desc.get("rurdu") or "").strip())
            res = m and links.resolve(m.group(1))
            if res and res[0] != nid:
                redirects[nid] = res
    links.redirects = redirects
    for nid in list(redirects):
        target = links.follow(nid)
        if target[0] == nid:  # a loop of aliases: keep them as ordinary pages
            del redirects[nid]
        else:
            redirects[nid] = target
    print(f"   {len(redirects)} alias entries redirect to their target page")

    # Walk the tree in reading order so search results come back in book order.
    order = []

    def walk(parent_key):
        children = sorted((n for n in nodes.values()
                           if (n["parent"] if n["parent"] else ("cat", n["cat"])) == parent_key),
                          key=lambda n: n["num"] or 0)
        for n in children:
            order.append(n["id"])
            walk(n["id"])

    # visible categories first, then the hidden ones (link and search targets only)
    for c in categories + [c for c in all_categories if c not in categories]:
        walk(("cat", c["Id"]))

    pages = parts_n = images_n = texts_n = 0
    for nid in order:
        n = nodes[nid]
        redirect = redirects.get(nid)
        lines = [] if redirect else by_node.get(nid, [])
        has_page = 1 if lines else 0
        node_row = [nid, n["parent"], n["cat"], n["num"], n["en"], n["rurdu"], n["urdu"],
                    kids.get(nid, 0), has_page, redirect and redirect[0], redirect and redirect[1],
                    n["listed"], 0]
        title_text = " ".join(v for v in (n["en"], n["rurdu"], n["urdu"]) if v)
        if title_text and not redirect:
            add_text(out, nid, None, "title", title_text)
        if not lines:
            out.execute("INSERT INTO nodes VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", node_row)
            continue

        blocks, images, seen_ids, anchored = [], [], set(), []
        for ln, v in zip(lines, verse_numbers(lines)):
            anchor = ln["id"] not in seen_ids
            seen_ids.add(ln["id"])
            blocks.append((render_line(ln, v, anchor, links, nid, images), is_heading(ln)))
            anchored.append(ln if anchor else None)
        parts = split_parts(blocks)
        node_row[-1] = len(parts)
        out.execute("INSERT INTO nodes VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", node_row)
        i = 0
        for part_no, part in enumerate(parts, 1):
            for _ in part:
                ln = anchored[i]
                i += 1
                if ln is None:
                    continue
                if len(parts) > 1:
                    out.execute("INSERT INTO anchors VALUES (?,?,?)", (nid, ln["id"], part_no))
                for lang, raw in line_texts(ln):
                    add_text(out, nid, ln["id"], lang, raw, part_no)
                    texts_n += 1
            page = "\n".join(h for h, _ in part).encode("utf-8")
            out.execute("INSERT INTO pages VALUES (?,?,?,?)", (nid, part_no, len(page), zlib.compress(page, 9)))
        out.executemany("INSERT OR REPLACE INTO images VALUES (?,?,?)", images)
        pages += 1
        parts_n += len(parts)
        images_n += len(images)

    build_id = time.strftime("%Y%m%d%H%M%S")
    out.executemany("INSERT INTO meta VALUES (?,?)", [
        ("schema", str(SCHEMA_VERSION)), ("build", build_id), ("source", os.path.basename(src)),
        ("include_hidden", "1" if include_hidden else "0")])
    out.commit()
    print(f"   {pages} pages ({parts_n} files after splitting long ones), {images_n} images, "
          f"{texts_n} searchable texts")
    print("▶ Optimising …")
    out.execute("INSERT INTO fts (fts) VALUES ('optimize')")
    out.commit()
    out.execute("VACUUM")
    out.close()
    con.close()
    print(f"\n✅ {dst} ({os.path.getsize(dst) / 1024 / 1024:.1f} MB, build {build_id})")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Build duas.sqlite for the Duas KOReader plugin.")
    ap.add_argument("source", help="ron.db")
    ap.add_argument("output", help="duas.sqlite to write")
    ap.add_argument("--include-hidden", action="store_true",
                    help="also list subindex rows marked IsVisible = 0 when browsing (e.g. Ramazan, On Occasions)")
    args = ap.parse_args()
    build(args.source, args.output, args.include_hidden)
