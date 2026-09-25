#!/usr/bin/env python3
"""Rebuild a ron.db-shaped SQLite file from docs/data JSON, for testing only.

Usage: python3 tools/make_fake_db.py <DUASRON>/docs/data fake_ron.db
"""
import json, os, sqlite3, sys

src, dst = sys.argv[1], sys.argv[2]
if os.path.exists(dst):
    os.remove(dst)
con = sqlite3.connect(dst)
c = con.cursor()
ar_cols = []
for i in range(1, 17):  # ron.db has ArabicText1..16
    ar_cols += [f"ArabicText{i}", f"ArabicGreenSign{i}", f"ArabicRedSign{i}", f"ArabicBlueSign{i}"]
c.executescript(f"""
CREATE TABLE categories (Id INTEGER, Number INTEGER, EnglishName TEXT, RUrduName TEXT, UrduName TEXT, IsVisible INTEGER);
CREATE TABLE subindex (Id INTEGER, ParentId INTEGER, Level INTEGER, Number INTEGER, HasChildren INTEGER,
  EnglishIndexName TEXT, RUrduIndexName TEXT, UrduIndexName TEXT, EnglishName TEXT, RUrduName TEXT, UrduName TEXT,
  CategoryId INTEGER, AudioIndexId INTEGER, IsVisible INTEGER,
  HyperlinkEnglishName TEXT, HyperlinkRUrduName TEXT, HyperlinkUrduName TEXT, IsNavigableMap INTEGER);
CREATE TABLE linesmetadata (LinesId INTEGER, SubindexId INTEGER, Number INTEGER);
CREATE TABLE lines (Id INTEGER, Sequence INTEGER, EnglishTitle TEXT, RUrduTitle TEXT, UrduTitle TEXT,
  EnglishDescription TEXT, RUrduDescription TEXT, UrduDescription TEXT, English TEXT, RUrdu TEXT, Urdu TEXT,
  RArabic TEXT, EnglishImage TEXT, RUrduImage TEXT, UrduImage TEXT, IsRed INTEGER,
  MinimizeDescriptionLine INTEGER, IsPrintable INTEGER, {", ".join(c + " TEXT" for c in ar_cols)});
CREATE TABLE audioindex (Id INTEGER);
""")
cats = json.load(open(f"{src}/categories.json"))
names = {6: "Hidden six", 7: "Hidden seven"}
for x in cats:
    c.execute("INSERT INTO categories VALUES (?,?,?,?,?,1)", (x["id"], x["num"], x["en"], x["rurdu"], x["urdu"]))
for k, v in names.items():
    c.execute("INSERT INTO categories VALUES (?,?,?,?,?,0)", (k, k, v, v, v))
nav = json.load(open(f"{src}/nav.json"))

def walk(nodes):
    for n in nodes:
        hl = n.get("hyperlink") or {}
        c.execute("INSERT INTO subindex VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,1,?,?,?,?)", (
            n["id"], n["parentId"], n["level"], n["num"], int(n["hasKids"]),
            n["title"]["en"], n["title"]["rurdu"], n["title"]["urdu"],
            n["name"]["en"], n["name"]["rurdu"], n["name"]["urdu"],
            n["catId"], n.get("audioId"), hl.get("en") or "0", hl.get("rurdu") or "0", hl.get("urdu") or "0",
            int(n.get("isMap", False))))
        walk(n.get("children", []))

for v in nav.values():
    walk(v)

cols = ["Id", "Sequence", "EnglishTitle", "RUrduTitle", "UrduTitle", "EnglishDescription", "RUrduDescription",
        "UrduDescription", "English", "RUrdu", "Urdu", "RArabic", "EnglishImage", "RUrduImage", "UrduImage",
        "IsRed", "MinimizeDescriptionLine", "IsPrintable"] + ar_cols
ins = f"INSERT INTO lines ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})"
L = {"en": "English", "rurdu": "RUrdu", "urdu": "Urdu"}
for f in os.listdir(f"{src}/lines"):
    d = json.load(open(f"{src}/lines/{f}"))
    for num, ln in enumerate(d["lines"], 1):
        row = dict.fromkeys(cols)
        row.update(Id=ln["id"], Sequence=ln.get("seq"), IsRed=int(ln.get("isRed", False)),
                   MinimizeDescriptionLine=int(ln.get("minimizeDesc", False)),
                   IsPrintable=int(ln.get("isPrintable", False)))
        if ln["type"] == "image":
            for k, v in ln["images"].items():
                row[L[k] + "Image"] = v.split(",", 1)[1]
        for k, pre in L.items():
            row[pre + "Title"] = (ln.get("title") or {}).get(k)
            row[pre + "Description"] = (ln.get("desc") or {}).get(k)
            row[pre] = (ln.get("trans") or {}).get(k)
        row["RArabic"] = ln.get("rarabic")
        for i, s in enumerate(ln.get("arabic") or [], 1):
            row[f"ArabicText{i}"] = s["text"]
            row[f"ArabicGreenSign{i}"] = s.get("green")
            row[f"ArabicRedSign{i}"] = s.get("red")
            row[f"ArabicBlueSign{i}"] = s.get("blue")
        c.execute("INSERT OR IGNORE INTO lines ({}) SELECT {} WHERE NOT EXISTS (SELECT 1 FROM lines WHERE Id=?)".format(
            ",".join(cols), ",".join("?" * len(cols))), [row[k] for k in cols] + [ln["id"]])
        c.execute("INSERT INTO linesmetadata VALUES (?,?,?)", (ln["id"], d["subindexId"], num))
con.commit()
print("ok", os.path.getsize(dst) // 1e6, "MB")
