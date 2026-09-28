---
schema: 2
slug: ronkindle-duas-koreader
title: "RONkindle: Duas for KOReader"
tagline: The Path to Supplication collection as a KOReader plugin for Kindle
publish: true
reason: ""
status: active
kind: tool
size: small
started: 2026-09
ended: null
role: "Owner — scoped, designed, built, tested"
summary: A KOReader plugin that brings the Path to Supplication collection (Qur'an, Namaz, Dua, Ziyarat, A'maal) to a Kindle, with per-language show and hide, working cross-references and full-text search in five languages, pre-rendered on a computer so the e-reader stays light.
problem: The Path to Supplication content lives in a phone app. Reading long Arabic texts with translations on an e-ink Kindle means either a PDF that cannot hide languages or search, or nothing at all.
stack: [Lua, LuaJIT, KOReader, SQLite, FTS5, Python, HTML, CSS, Bash]
categories: [embedded, data, reliability]
links: { live: "", docs: "", demo: "" }
metrics:
  - value: "8,518"
    label: "cross-references turned into working links, including jumps to a verse"
    evidence: "README.md (Features) ; CHANGELOG.md (1.0.0)"
  - value: "2,894"
    label: "page parts of about 60 KB pre-rendered from 2,646 pages, so the device only loads the part it shows"
    evidence: "scripts/build_kindle_db.py (build output) ; docs/DEVELOPMENT.md (How it works)"
  - value: "1.4 s"
    label: "to open the longest surah (Baqarah, part 1 of 9) on a Kindle Paperwhite; search in 0.1–0.2 s"
    evidence: "README.md (Performance)"
  - value: "31–57 MB"
    label: "whole KOReader process while browsing, reading and searching on the Kindle"
    evidence: "README.md (Performance) ; docs/DEVELOPMENT.md (On a Kindle)"
  - value: "63/63"
    label: "scripted checks inside a real KOReader build, plus 5/5 after a restart"
    evidence: "tools/emulator/2-duas-emu-test.lua ; commit ea07863"
highlights:
  recruiter:
    - Turned a phone app's database into a readable e-ink edition: five languages that can each be shown or hidden while reading, without losing the reader's place.
    - Kept the e-reader light by moving all rendering to a build step on the computer, then measured it on a real Kindle Paperwhite instead of relying on the emulator estimate.
    - Shipped with tests that use the plugin the way a person does, including a pixel-for-pixel check that toggling a language matches a fresh reload.
  engineer:
    - A Python build step renders every page into HTML blocks with one CSS class per language and stores them zlib-compressed in SQLite; pages over about 60 KB are split at line boundaries, never after a heading.
    - Show and hide only re-applies a stylesheet through KOReader's style-tweak hook, so the document and the reading position never change; the reload prompt is suppressed only on the plugin's own pages.
    - Full-text search is a contentless FTS5 index over normalised text (harakat and Qur'anic marks removed, letter variants unified), with the same normalisation implemented in Python and Lua and tested to match.
    - `duas:` links are handled by wrapping KOReader's link handler, covering pages, verses, split parts and alias entries.
    - The database is opened only to browse, search or open a page and closed while reading, with a 256 KB SQLite cache and no memory mapping; modules load on first use.
  story: ""
skills: [Data pipeline design, Performance on constrained devices, Search and text normalisation, Test strategy, On-device testing, Technical documentation, Platform integration]
ai_assisted: true
media: [docs/screenshots/browser.png, docs/screenshots/reader.png, docs/screenshots/arabic-only.png, docs/screenshots/show-menu.png]
todo_owner:
  - "Why did you build this, and who is it for? A 1–3 sentence first-person story would fill highlights.story."
  - "NOTICE.md says the content belongs to the Path to Supplication app's owners. Do you have their permission to publish builds, and is it fine to feature the project publicly?"
  - "The README points to release zips, but no GitHub release exists yet. Publish one (with duas.sqlite) and use it as links.live?"
  - "Any readers using it, or feedback, to cite?"
generated: { at: 2026-09-28, commit: 629ba07 }
---

## Overview

RONkindle is a KOReader plugin for reading the *Path to Supplication* collection (the Qur'an, Namaz, Dua, Ziyarat and A'maal) on a Kindle or any other device that runs KOReader. It keeps the app's structure, lets the reader choose which languages to show, makes every cross-reference tappable and searches all five languages.

## The problem

The collection exists as a phone app. On an e-ink reader the usual fallback is a PDF, which cannot hide a language, follow a reference to a verse or search Urdu without its diacritics. E-readers are also slow and low on memory, so a large database cannot simply be rendered on the device.

## What I built

- A build script that turns the app's database into `duas.sqlite`: every page rendered in advance, split into parts of about 60 KB, links resolved and a search index built.
- A KOReader plugin that browses the collection like the app (categories, sections, breadcrumbs, previous/next, the Path to Supplication shortcuts) and opens each part in KOReader's normal reader.
- Show and hide for Arabic, transliteration, English, Roman Urdu, Urdu, notes, verse numbers and waqf signs, each also assignable to a gesture.
- Search in every language with snippets, 50 results at a time, and bookmarks alongside KOReader's own.
- A centred page layout for Arabic and translations alike, and an optional Amiri Arabic font.
- Off-device tests with KOReader's real SQLite and zlib bindings, scripted tests inside a real KOReader build, and a benchmark run on a Kindle Paperwhite.

## Architecture

- Build (`scripts/build_kindle_db.py`): reads `ron.db`, writes a versioned SQLite file with nodes, compressed page parts, verse anchors, images and an FTS5 index.
- Plugin (`duas.koplugin/`): menus and browser views, a read-only database layer, a page writer that materialises one part as an HTML file on demand, the stylesheet with show/hide rules, and a search normaliser that mirrors the Python one.
- Integration with KOReader through its style-tweak hook (show/hide), its link handler (`duas:` links) and its dispatcher (gestures), without patching KOReader.
- Tests: `tools/run_tests.sh` off the device, `tools/emulator/` inside KOReader (menus, pages, toggles, links, search, bookmarks, font, restart), and `2-duas-bench.lua` for timings and memory.

## Key decisions

- **Render on the computer, not the e-reader.** All HTML, links and the search index are built in advance, so the device only reads one compressed part and writes it to a file when it is opened.
- **Toggle languages with CSS, not new documents.** Each part of a line has its own class, and switching a language re-applies a stylesheet. The document never changes, so the reading position is kept and no reload is needed; the tests compare the result with a fresh reload pixel for pixel.
- **Split long pages at line boundaries.** Baqarah alone is split into 9 parts of about 60 KB; links, search results and bookmarks open the right part.
- **Close the database while reading.** It is opened only to browse, search or open a page, with a small SQLite cache and no memory mapping.
- **Normalise text the same way in two languages.** Search removes harakat and Qur'anic marks in both Python (at build time) and Lua (at query time), and a test checks both give the same result.

## Results

- 8,518 cross-references work as links, including jumps to a verse inside a split page.
- 2,646 pages are pre-rendered into 2,894 parts; the build takes about 15 s and produces a 30 MB database.
- On a Kindle Paperwhite (firmware 5.19.5): the browser opens in 0.1 s, Baqarah in 1.4 s, a language toggle takes 0.6 s, search 0.1–0.2 s and a verse jump 1.2 s, with the whole KOReader process at 31–57 MB.
- Scripted tests inside a real KOReader build pass 63/63, plus 5/5 after a restart.
- The plugin was installed on that Kindle from the repository's GitHub download through Kindle-style Home's Send Plugin.

## What's next

- Publish a release zip that includes `duas.sqlite`, so installing no longer needs the Python build.
- Show the sub-entry lists on the device in the new centred layout and adjust spacing if needed.
- Confirm permission for the content before promoting builds more widely.
