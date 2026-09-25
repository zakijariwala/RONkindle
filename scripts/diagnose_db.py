#!/usr/bin/env python3
"""Usage: py scripts/diagnose_db.py path/to/ron.db"""
import sqlite3, sys

db = sys.argv[1] if len(sys.argv) > 1 else input("Path to ron.db: ")
con = sqlite3.connect(db)
cur = con.cursor()

EXPECTED = {
    "categories":    ["Id","Number","EnglishName","RUrduName","UrduName","IsVisible"],
    "subindex":      ["Id","ParentId","Level","Number","HasChildren","EnglishIndexName",
                      "RUrduIndexName","UrduIndexName","EnglishName","RUrduName","UrduName",
                      "CategoryId","AudioIndexId","IsVisible"],
    "audioindex":    ["Id","Number","EnglishIndexName","RUrduIndexName","UrduIndexName",
                      "QuranQaari1Audio","QuranQaari2Audio","QuranQaari3Audio","QuranQaari4Audio",
                      "QuranWithTranslationAudio","NonQuranAudio","CategoryId"],
    "linesmetadata": ["LinesId","SubindexId","Number"],
    "lines":         ["Id","Sequence","EnglishTitle","RUrduTitle","UrduTitle",
                      "EnglishDescription","RUrduDescription","UrduDescription",
                      "English","RUrdu","Urdu","RArabic",
                      "EnglishImage","RUrduImage","UrduImage",
                      "IsRed","MinimizeDescriptionLine",
                      "ArabicText1","ArabicGreenSign1","ArabicRedSign1","ArabicBlueSign1"],
}

cur.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
actual_tables = {r[0] for r in cur.fetchall()}
print("=== ALL TABLES IN DB ===")
for t in sorted(actual_tables):
    print(f"  {t}")

print("\n=== SCHEMA COMPARISON ===")
for table, expected_cols in EXPECTED.items():
    if table not in actual_tables:
        print(f"\nMISSING TABLE: {table}")
        continue
    cur.execute(f"PRAGMA table_info({table})")
    actual_cols = {r[1] for r in cur.fetchall()}
    missing = [c for c in expected_cols if c not in actual_cols]
    extra   = sorted(actual_cols - set(expected_cols))
    print(f"\n{table}")
    if missing: print(f"  MISSING cols (export will skip): {missing}")
    if extra:   print(f"  EXTRA cols (not exported):       {extra}")
    if not missing and not extra: print("  OK - perfect match")

print("\n=== ROW COUNTS ===")
for table in ["categories","subindex","linesmetadata","lines","audioindex"]:
    if table in actual_tables:
        cur.execute(f"SELECT COUNT(*) FROM {table}")
        print(f"  {table}: {cur.fetchone()[0]}")

con.close()
