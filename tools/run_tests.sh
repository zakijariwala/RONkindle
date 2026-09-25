#!/bin/bash
# Off-device tests for duas.koplugin.
#   tools/run_tests.sh <source ron.db> <duas.sqlite> <koreader-base checkout>
# Needs python3, luajit, libsqlite3 (with FTS5) and zlib.
set -euo pipefail
src_db=$1 duas_db=$2 base=$3
here=$(cd "$(dirname "$0")" && pwd)
vectors=$(mktemp)
trap 'rm -f "$vectors"' EXIT

# Normalisation test vectors: Python's normalize() over real text from the source DB.
python3 - "$src_db" "$vectors" "$here/../scripts" <<'EOF'
import sqlite3, sys
sys.path.insert(0, sys.argv[3])
from build_kindle_db import normalize
con = sqlite3.connect(sys.argv[1])
cols = [r[1] for r in con.execute("PRAGMA table_info(lines)")]
wanted = [c for c in ("ArabicText1", "Urdu", "RUrdu", "English", "RArabic", "UrduTitle") if c in cols]
with open(sys.argv[2], "w", encoding="utf-8") as out:
    for col in wanted:
        for (v,) in con.execute(f"SELECT {col} FROM lines WHERE {col} IS NOT NULL AND {col} != '' LIMIT 1500"):
            v = " ".join(str(v).split())  # no tabs/newlines in the TSV
            out.write(f"{v}\t{normalize(v)}\n")
EOF

luajit "$here/test_offdevice.lua" "$base" "$duas_db" "$vectors"
