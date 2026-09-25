# Duas for KOReader (Kindle)

A KOReader plugin for reading the Path to Supplication content (Qur'an, Namaz, Dua, Ziyarat, A'maal) on a jailbroken Kindle.
- **Toggles:** show or hide Arabic, transliteration, English, Roman Urdu, Urdu, notes, verse numbers and waqf signs while reading, without losing your place.
- **Bookmarks:** save any dua to a list. KOReader's own bookmarks and highlights also work inside pages.
- **Search:** search all languages, including Arabic and Urdu typed without harakat.

## 1. Build the database (on your computer)
```bash
python3 scripts/build_kindle_db.py ron.db duas.sqlite
```
This needs only Python 3, with no extra packages, and takes about 15 seconds. It produces a file of about 29 MB.

**Hidden entries:** entries the original app marks hidden (`IsVisible = 0`) behave as they do there. They aren't listed when you browse, but links and search still open them. 631 links on ordinary pages lead to them, such as Namaz-e-Shab's links to its parts. To list them when browsing as well, add `--include-hidden`.

**Links:** a `<Name>` reference in the text becomes a tappable link. A verse reference such as `<Aale Imran (3:18-19)>` jumps to that verse. An entry that only points to another page, such as Dua-e-Kumail in Path to Supplication, opens that page directly.

**Numbering:**
- Qur'an pages show the source's own verse numbers.
- Instruction steps show "1.", "2." and so on, as in the app.
- Other pages number every Arabic line that isn't a heading.

## 2. Copy to the Kindle
Connect the Kindle over USB and copy:

| From | To |
|---|---|
| `duas.koplugin/` | `koreader/plugins/duas.koplugin/` |
| `duas.sqlite` | `koreader/duas/duas.sqlite` |

The plugin also finds `duas.sqlite` if it's placed inside `duas.koplugin/`.

## 3. Use it
- **Open it:**
  - from the file browser: **Tools (⚙) → Duas**;
  - while reading a dua: **Navigation (☰) → Duas**.
- **Browse:** tap a category, then a section, then an item. Press and hold an item to bookmark it.
- **Show:** pick the parts you want. The page restyles in place, and it takes about a second.
- **Install Amiri Arabic font:** do this once, then restart KOReader. It gives nicer Qur'anic text; without it, KOReader uses Noto Naskh Arabic.
- **Links:** tapping a link inside a page (a referenced dua, the breadcrumb, previous/next, a child list) opens that page.
- **Gestures:** in **Settings → Taps and gestures → Gesture manager**, pick a gesture, go to **General**, and choose any of these:
  - *Duas: browse*
  - *Duas: search*
  - *Duas: bookmarks*
  - *Duas: Path to Supplication*
  - *Duas: show/hide …*

  For example, a two-finger swipe could toggle English.

## How it keeps the Kindle light
- Everything is pre-rendered on the computer, and each page is compressed in the database.
- On the Kindle, opening an item writes one small HTML file to `koreader/duas/pages/` and opens it in KOReader's normal reader. Only that item is ever loaded.
- Pages are regenerated only when the database changes.
- Toggles change the stylesheet rather than the document.
- Search uses a SQLite FTS5 index built into the database.

## Development
- **Plugin code:** `duas.koplugin/` (`main.lua` plus the `duas*.lua` modules).
- **Off-device tests:** they need LuaJIT and a checkout of `koreader-base`.
  ```bash
  git clone --depth 1 https://github.com/koreader/koreader-base.git
  tools/run_tests.sh ron.db duas.sqlite koreader-base
  ```
  They cover:
  - the database queries, page generation, snippets, search and styles;
  - that search normalisation gives the same result in Lua as in Python;
  - a smoke test of `main.lua` using stand-ins for KOReader's UI.
- **In-app tests:** these run the plugin inside a real KOReader (the official Linux AppImage) on a virtual Kindle-sized, greyscale screen. They need `curl` and `xvfb-run`.
  ```bash
  tools/emulator/run_emulator_tests.sh duas.sqlite /tmp/duas-emu
  ```
  The script `2-duas-emu-test.lua` is installed as a KOReader user patch and uses the plugin as a person would:
  - menus and the browser;
  - opening pages, and timing them;
  - toggles, checking that the reading position is kept, that no reload prompt appears, and that a toggled page matches a freshly loaded one pixel for pixel;
  - tapping links, including verse links and alias entries;
  - search, bookmarks, Path to Supplication, image pages and gesture actions;
  - installing the Amiri font;
  - after a restart, that settings and bookmarks were kept and Amiri is used.

  Screenshots and `results-phase*.txt` are written to `<workdir>/shots`.
- **Without `ron.db`:** `tools/make_fake_db.py <DUASRON>/docs/data fake_ron.db` builds a stand-in from the web app's exported JSON (in the DUASRON repo).
