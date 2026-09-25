# Duas KOReader plugin: status

Repository: `zakijariwala/RONkindle` (moved here from the DUASRON repo). The README covers install and use; this page covers the project's state.

## State
- **`scripts/build_kindle_db.py`** builds `duas.sqlite`, database format 3, from `ron.db`.
  - It contains 3,001 entries, 2,646 pages and 8,518 links. No link is broken, and 80 of them jump to a specific verse.
  - It builds in about 15 seconds, and the file is about 29 MB.
- **`duas.koplugin/`** is the complete plugin.
- **Tested in a real KOReader,** version v2026.07.2 (the official Linux AppImage), on a virtual Kindle-sized greyscale screen at 1072×1448 and 300 dpi.
  - `tools/emulator/run_emulator_tests.sh` runs the tests.
  - Result: 59 of 59 checks pass in the first part and 5 of 5 after a restart.
- **Off-device tests:** `tools/run_tests.sh` passes 51 of 51 checks against the real `ron.db`.

## Decisions made
- **Hidden entries (`IsVisible = 0`):** they behave as in the source app. They aren't listed when browsing, but links and search open them.
  - 631 links on ordinary pages lead to them. For example, Namaz-e-Shab links to Nafelah-e-Shab, Namaz-e-Shafa and Namaz-e-Vatr.
  - `--include-hidden` lists them when browsing too.
- **Verse numbers:**
  - Qur'an pages use the source's own verse numbers (`Sequence`).
  - Numbered instruction steps show as "1.", "2." and so on.
  - Every other page numbers each Arabic line that isn't a heading.
- **`<Name>` references** in the text become links. Alias entries, whose only line is a pointer to another page, open that page directly.
- **Reload prompt:** KOReader's "reload the document?" prompt after each toggle is suppressed on Duas pages. The in-app test shows that a toggled page is pixel-identical to the same page after a full reload.

## Bugs found by the in-app run, all fixed
- The plugin never found `duas.sqlite`, because of the empty first entry in its list of places to look.
- Every toggle popped up the "reload the document?" prompt.
- Inline `<Name>` links were shown as literal text.
- Alias entries opened empty pages. Dua-e-Kumail in Path to Supplication was one of them.
- Links into hidden entries were lost.
- Search showed the same line once per matching language.
- Urdu titles sat at the right edge instead of centred.

## Timings on a desktop CPU (the Kindle will be several times slower)
- Opening Baqarah, the largest page at 338 screens, takes 2.5 s.
- Toggling English on Baqarah takes 2.1 s.
- A search takes 0.01 s.

## Still open
- **Speed on a real Kindle.** If the longest pages feel slow, split them into parts.
- **`ron.db` is committed** at the repo root (88 MB), while `HANDOVER.md` says it never is. Update one or the other.
- **Source-data typos:** 3 Urdu descriptions write the link brackets backwards (`>…<`), on entries 2272, 2471 and 3575. They're shown as they are.
