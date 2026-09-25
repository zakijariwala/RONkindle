# Development

## Layout
```
duas.koplugin/        the KOReader plugin
  main.lua            menus, browser views, toggles, links, bookmarks, search, font install
  duasdb.lua          read-only access to duas.sqlite (lua-ljsqlite3, zlib)
  duaspages.lua       writes one small HTML file per page part, on demand; search snippets
  duasstyle.lua       the stylesheet, and the show/hide rules
  duasbrowser.lua     full-screen list (a KOReader Menu) with a stack of views
  duasnormalize.lua   search normalisation (must match scripts/build_kindle_db.py)
  duasquicklist.lua   the Path to Supplication shortcuts
  fonts/              Amiri (OFL)
scripts/
  build_kindle_db.py  ron.db → duas.sqlite
  diagnose_db.py      checks a ron.db against the expected schema
tools/
  run_tests.sh, test_offdevice.lua   off-device tests (LuaJIT)
  emulator/                          tests and benchmarks inside a real KOReader
  make_fake_db.py                    stand-in ron.db from the web app's JSON export
  package.sh                         release archives
```

## How it works
**On the computer**, `build_kindle_db.py` reads `ron.db` and writes `duas.sqlite`. Everything is rendered in advance.
- **Every line of every page** is an HTML block. Each part of a line has its own class: `x-ar`, `x-tr`, `x-en`, `x-ru`, `x-ur`, `x-notes`, `x-vn`.
- **`<Name>` references** become links:
  - `duas:<node>` opens a page;
  - `duas:<node>:<line>` opens a page at a verse;
  - `duas:<node>/<part>` opens a given part of a page.
- **Alias entries,** whose only line points to another page, redirect to it.
- **Pages over about 60 KB** are split into parts at line boundaries. A part never ends on a heading.
- **Search:** each line is indexed per language in a contentless FTS5 table (`detail=none`). The text is first normalised: harakat and Qur'anic marks are removed, letter variants are unified, and apostrophes are dropped.

**On the device**, the plugin looks for `duas.sqlite` in `<koreader>/duas/`, then in the plugin folder.
- **Opening a page part** writes it to `<koreader>/duas/pages/<node>_<part>-<slug>.html`. The images go to `pages/img/`. The part then opens in KOReader's normal reader. Cached files are cleared when the database build changes.
- **Show/hide:** the plugin appends its stylesheet to `ReaderStyleTweak.getCssText` and fires `ApplyStyleSheet`. The document never changes, so the reading position is kept.
  - KOReader normally suggests a full reload after display changes. The plugin suppresses that prompt on its own pages.
  - The emulator test checks this is safe: a toggled page must match a freshly reloaded one pixel for pixel.
- **Links:** `ReaderLink.onGotoLink` is wrapped to handle `duas:` links.
- **Lightness:**
  - Modules other than `duaspages` and `duasstyle` load on first use.
  - The database is opened only to browse, search or open a page, and closed while reading.
  - SQLite gets a 256 KB page cache and no memory mapping.
  - Plain lists are drawn single-line; only search results are multi-line.
  - Search results come 50 at a time, with snippets cut only for those.

## Database format (`meta.schema` = 4)
| Table | Contents |
|---|---|
| `meta` | `schema`, `build`, `source`, `include_hidden` |
| `categories` | the visible categories |
| `nodes` | `id, parent, cat, num, en, rurdu, urdu, kids, has_page, redirect, redirect_line, listed, parts` |
| `pages` | `(node, part)` → `size` and zlib-compressed `body` |
| `anchors` | `(node, line)` → `part`, for pages that are split |
| `images` | `name, node, data` (PNG) |
| `texts` + `fts` | `id, node, line, lang, part`, plus the FTS5 index of the normalised text |

The plugin refuses a database of any other format and asks for a rebuild.

## Tests
**Off-device.** Requirements: LuaJIT and a `koreader-base` checkout.
```bash
git clone --depth 1 https://github.com/koreader/koreader-base.git
python3 scripts/build_kindle_db.py ron.db duas.sqlite
tools/run_tests.sh ron.db duas.sqlite koreader-base
```
These use koreader-base's real `lua-ljsqlite3` and zlib bindings. They cover:
- the database queries, parts, page files, snippets, search and styles;
- that normalisation gives the same result in Lua as in Python;
- a smoke test of `main.lua` with stand-ins for KOReader's UI.

**In a real KOReader.** Requirements: `curl` and `xvfb-run`.
```bash
tools/emulator/run_emulator_tests.sh duas.sqlite /tmp/duas-emu
```
This downloads the official Linux AppImage, installs the plugin and database into a fresh profile, and runs `2-duas-emu-test.lua` as a KOReader user patch. The patch uses the plugin as a person would:
- the menus and the browser;
- opening pages;
- toggles, checking that the position is kept, that no prompt appears, and that the page matches a fresh reload pixel for pixel;
- tapping links, parts, verse links and aliases;
- search, bookmarks, images and dispatcher actions;
- installing the font;
- after a restart, that the settings and the font are kept.

Screenshots and `results-phase*.txt` are written to `<workdir>/shots`.

## Benchmarks and throttling
```bash
DRIVER=2-duas-bench.lua PHASES=1 \
RUN_WRAPPER=$PWD/tools/emulator/limit.sh CPU_PCT=10 \
    tools/emulator/run_emulator_tests.sh duas.sqlite /tmp/duas-bench
```
- `2-duas-bench.lua` times the main operations, polling for completion, and records memory.
- `limit.sh` runs KOReader, and not the X server, in a cgroup (v1, needs root). `CPU_PCT` limits the CPU and `MEM_MB` the memory.
- `PLUGIN_DIR` benchmarks another checkout of the plugin.

Memory figures from the desktop AppImage are dominated by KOReader's desktop libraries. They're much higher than on an e-reader.

## Releasing
1. Bump `version` in `duas.koplugin/_meta.lua` and add an entry to `CHANGELOG.md`.
2. Run both test suites.
3. Run `tools/package.sh`, then attach `dist/duas-kindle-<version>.zip` and `dist/duas.koplugin-<version>.zip` to a GitHub release.

## Known data quirks
Three Urdu descriptions in the source write link brackets backwards (`>…<`), on entries 2272, 2471 and 3575. They're shown as they are.
