---
schema: 2
slug: duas-for-koreader
title: "RONkindle: Duas for KOReader"
tagline: Multilingual prayer collection as an e-reader plugin
publish: true
reason: ""
status: shipped
kind: product
size: medium
started: 2026-09
ended: null
role: "Owner — scoped, designed, built, released"
summary: Brought the Path to Supplication collection to Kindle and other KOReader devices as a v1.0.0 plugin, with per-language show/hide, 8,518 working links and full-text search in 5 languages.
problem: The Path to Supplication collection only existed as a web app, with no way to read it on an e-ink device that has little memory, a slow CPU and no reliable connection.
stack: [Lua, LuaJIT, SQLite FTS5, Python, KOReader, zlib, Bash]
categories: [embedded, product, data]
links: { live: "", docs: "", demo: "" }
metrics:
  - value: "8,518"
    label: "cross-references turned into tappable links"
    evidence: "README.md ; CHANGELOG.md ; scripts/build_kindle_db.py"
  - value: "0.1 s"
    label: "search time, even for very common words, at 10% of one CPU core"
    evidence: "README.md (Performance)"
  - value: "63/63"
    label: "emulator checks passing inside a real KOReader build"
    evidence: "commit ea07863"
  - value: "~60 KB"
    label: "maximum page part size, so the longest surah opens in 1.5 s"
    evidence: "README.md (Performance) ; docs/DEVELOPMENT.md"
highlights:
  recruiter:
    - Took an existing web product to a new, constrained platform and released it as v1.0.0 with licensing, changelog and install guide in place.
    - Set the performance budget by testing at 10% of one CPU core, so every common action finishes in 1.5 s or less.
    - Moved all heavy work off the device into a build step, so readers download one file and the device only loads the page they open.
  engineer:
    - A Python build step renders every line to HTML ahead of time, compresses pages with zlib, splits pages over about 60 KB at line boundaries and writes one SQLite file.
    - Search uses a contentless FTS5 index per language with normalisation that strips harakat and unifies letter variants, kept identical in Python and Lua and tested for parity.
    - Show/hide appends a stylesheet and reapplies it without changing the document, so position is kept; an emulator test checks each toggled page matches a fresh reload pixel for pixel.
    - Device lightness: lazy-loaded modules, database closed while reading, 256 KB SQLite page cache with no memory mapping, and search results paged 50 at a time.
    - Off-device LuaJIT tests plus emulator tests and benchmarks that download the official KOReader build, run the plugin as a user would and throttle it with cgroups.
  story: ""
skills: [Constrained-device performance, Offline data pipelines, Release management, Test automation, Search design, Open-source licensing]
ai_assisted: true
media:
  - { path: docs/screenshots/reader.png, alt: "Surah Fateha shown with Arabic and all translations on an e-reader screen" }
  - { path: docs/screenshots/show-menu.png, alt: "The Show menu for switching languages and notes on and off while reading" }
  - { path: docs/screenshots/search.png, alt: "Search results with snippets across languages" }
todo_owner:
  - "Why did you want the collection on an e-reader? A 1–3 sentence first-person story would fill highlights.story."
  - "Has a v1.0.0 GitHub release been published, and has it been tested on a real Kindle? Performance figures in README.md come from an emulator."
  - "The source database is included in the repo while NOTICE.md says the content belongs to its owners. Do you have permission to distribute it, and should the entry mention that?"
  - "Any readers or feedback to cite?"
generated: { at: 2026-09-27, commit: bc82fc5 }
---

## Overview

RONkindle is a KOReader plugin for reading the Path to Supplication collection (Qur'an, Namaz, Dua, Ziyarat and A'maal) on a Kindle or any other device that runs KOReader. It keeps the web app's structure and multilingual display, and adapts them to e-ink: pre-rendered pages, instant language switching, working cross-references and fast search.

## The problem

The collection already existed as an offline web app, but e-ink readers are a different target. They have little memory, slow processors and a reader engine that expects documents rather than a single-page app. Readers also wanted to hide or show languages without losing their place, and to follow the many internal references between texts.

## What I built

- A build script that converts the app's source database into a single compressed SQLite file with pages, images, anchors and a search index.
- A KOReader plugin with a category browser, breadcrumbs, previous and next links, the Path to Supplication shortcuts and bookmarks.
- Show and hide switches for Arabic, transliteration, English, Roman Urdu, Urdu, notes, verse numbers and waqf signs, each also available as a gesture.
- 8,518 tappable cross-references, including verse references that jump to the exact line in the right part of a page.
- Search across every language, with Arabic and Urdu matching without diacritics and snippets for each result.
- An optional Arabic font installer, an off-device test suite, emulator tests and benchmarks, and a packaging script for releases.

## Architecture

- **On the computer:** the build script reads the source database, renders each line as HTML with a class per language, rewrites references as internal links, resolves alias entries, splits long pages into parts and indexes normalised text in FTS5.
- **On the device:** the plugin finds the database, writes a page part to a small HTML file only when opened, and hands it to KOReader's normal reader.
- **Styling:** a stylesheet of show/hide rules is appended to KOReader's style tweaks and reapplied in place.
- **Links:** KOReader's link handler is wrapped to resolve the plugin's own link scheme.
- **Versioning:** the database carries a schema number, and the plugin refuses a mismatched file and asks for a rebuild. Cached page files are cleared when the build changes.

## Key decisions

- **Render everything ahead of time.** The device only reads a compressed page and writes one small file, instead of building pages at read time. The full build takes about 15 seconds on a computer and keeps the device light.
- **Split long pages at about 60 KB.** The longest surah comes in 9 parts and opens in 1.5 s at 10% of one core. Anchors map each verse to its part so links, search and bookmarks still land correctly.
- **Restyle, never reload.** Toggling a language changes CSS only. KOReader normally suggests a full reload after display changes; the plugin suppresses that prompt on its own pages, and the emulator test proves the result is identical to a reload.
- **One normalisation in two languages.** Search normalisation runs in Python at build time and in Lua at query time. A test checks both give the same output, because a mismatch would silently break search.
- **Test like a user, on a slow machine.** Benchmarks run in the official KOReader build throttled to 10% of one core, since desktop timings would hide e-ink constraints.

## Results

- Released as version 1.0.0 on 2026-09-25 with an AGPL-3.0 licence matching KOReader, a notice file for content and font licences, and a changelog.
- Emulator suite passing 63 of 63 checks, plus 5 of 5 in a second phase.
- Measured at 10% of one CPU core: browser opens in 0.5 s, the longest page in 1.5 s, a language toggle in 0.4–0.5 s and search in 0.1 s or less.

## What's next

- Publish the release archives on GitHub as described in the release steps.
- Record timings on real e-ink hardware, since current figures come from a throttled emulator.
