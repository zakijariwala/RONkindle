#!/bin/sh
# Build the release archives into dist/:
#   duas-kindle-<version>.zip    plugin + database, laid out to unzip onto the
#                                Kindle's USB drive (merges into koreader/)
#   duas.koplugin-<version>.zip  the plugin alone
# Usage: tools/package.sh [ron.db]
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
src=${1:-$root/ron.db}
version=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' "$root/duas.koplugin/_meta.lua")
dist=$root/dist
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$dist" "$stage/koreader/plugins" "$stage/koreader/duas"
python3 "$root/scripts/build_kindle_db.py" "$src" "$stage/koreader/duas/duas.sqlite"
cp -r "$root/duas.koplugin" "$stage/koreader/plugins/"
cp "$root/LICENSE" "$root/NOTICE.md" "$stage/koreader/plugins/duas.koplugin/"

rm -f "$dist/duas-kindle-$version.zip" "$dist/duas.koplugin-$version.zip"
(cd "$stage" && python3 -c "
import os, sys, zipfile
def pack(out, top, arc_base):
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for d, _, files in os.walk(top):
            for f in sorted(files):
                p = os.path.join(d, f)
                z.write(p, os.path.relpath(p, arc_base))
pack(sys.argv[1], 'koreader', '.')
pack(sys.argv[2], 'koreader/plugins/duas.koplugin', 'koreader/plugins')
" "$dist/duas-kindle-$version.zip" "$dist/duas.koplugin-$version.zip")
ls -l "$dist"/*"$version".zip
