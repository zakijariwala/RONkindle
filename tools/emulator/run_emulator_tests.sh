#!/bin/bash
# Run duas.koplugin inside a real KOReader (Linux AppImage build) on a virtual
# X display and drive it with 2-duas-emu-test.lua.
#
#   tools/emulator/run_emulator_tests.sh <duas.sqlite> [workdir]
#
# Needs curl, xvfb-run. Downloads the KOReader AppImage once into workdir.
#
# Optional environment:
#   RUN_WRAPPER    command prefix for KOReader only (not the X server), e.g. a
#                  script that moves itself into a CPU/memory-limited cgroup
#   DUAS_SLOW      multiplies every wait in the test driver (throttled CPU)
#   PHASE_TIMEOUT  seconds per phase (default 600)
#   DRIVER         patch to run (default 2-duas-emu-test.lua; 2-duas-bench.lua times operations)
#   PHASES         phases to run (default "1 2")
#   PLUGIN_DIR     plugin to install (default: this checkout's duas.koplugin)
# Screenshots and results-phase*.txt end up in <workdir>/shots.
set -uo pipefail
db=$(realpath "$1")
work=$(realpath -m "${2:-/tmp/duas-emu}")
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(realpath "${PLUGIN_DIR:-$here/../../duas.koplugin}")

mkdir -p "$work"
if [ ! -x "$work/squashfs-root/usr/lib/koreader/reader.lua" ]; then
    name=$(curl -fsS https://ota.koreader.rocks/koreader-appimage-x86_64-linux-gnu-latest-stable 2>/dev/null \
        || curl -fsS https://ota.koreader.rocks/koreader-appimage-x86_64-latest-stable)
    echo "Downloading $name"
    curl -fsS -o "$work/koreader.AppImage" "https://ota.koreader.rocks/$name" || exit 1
    chmod +x "$work/koreader.AppImage"
    (cd "$work" && ./koreader.AppImage --appimage-extract >/dev/null)
fi
ko="$work/squashfs-root/usr/lib/koreader"

run_phase() {
    local phase=$1
    # reader.lua's shebang is ./luajit, so it has to start from the KOReader dir.
    cd "$ko" || return
    DUAS_SHOTS="$work/shots" DUAS_PHASE=$phase DUAS_SLOW="${DUAS_SLOW:-1}" \
    HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" KO_MULTIUSER=1 \
    EMULATE_READER_W=1072 EMULATE_READER_H=1448 EMULATE_READER_DPI=300 SDL_AUDIODRIVER=dummy \
        timeout "${PHASE_TIMEOUT:-600}" xvfb-run -a -s "-screen 0 1200x1600x24" $RUN_WRAPPER ./reader.lua "$work/home" \
        > "$work/log-phase$phase.txt" 2>&1
    grep -E "^DUASTEST (FAIL|SUMMARY|TIMING)" "$work/log-phase$phase.txt"
    grep -E "Lua error|stack traceback|\\bERROR\\b" "$work/log-phase$phase.txt" | head -20
}

# Fresh profile: plugin + database installed the way the README describes.
rm -rf "$work/config" "$work/home" "$work/data" "$work/shots"
mkdir -p "$work/config/koreader/plugins" "$work/config/koreader/duas" "$work/config/koreader/patches" \
         "$work/home" "$work/data" "$work/shots"
ln -s "$plugin" "$work/config/koreader/plugins/duas.koplugin"
cp "$db" "$work/config/koreader/duas/duas.sqlite"
cp "$here/${DRIVER:-2-duas-emu-test.lua}" "$work/config/koreader/patches/"

for phase in ${PHASES:-1 2}; do run_phase "$phase"; done
cat "$work/shots/results-phase1.txt" "$work/shots/results-phase2.txt" 2>/dev/null | grep -E "^FAIL|checks"
cat "$work/shots/bench.txt" 2>/dev/null
