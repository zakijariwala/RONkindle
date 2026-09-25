#!/bin/sh
# Run a command inside a CPU- and memory-limited cgroup (cgroup v1, needs root).
#   CPU_PCT=2 MEM_MB=75 tools/emulator/limit.sh <command...>
# Use as RUN_WRAPPER for run_emulator_tests.sh to throttle KOReader only, e.g.
#   RUN_WRAPPER="$PWD/tools/emulator/limit.sh" CPU_PCT=2 DUAS_SLOW=50 PHASE_TIMEOUT=10800 \
#       tools/emulator/run_emulator_tests.sh duas.sqlite /tmp/duas-emu
# Leave MEM_MB unset for no memory limit (peak usage is still measured).
set -e
cpu=/sys/fs/cgroup/cpu/duas-limit
mem=/sys/fs/cgroup/memory/duas-limit
mkdir -p "$cpu" "$mem"
echo 100000 > "$cpu/cpu.cfs_period_us"
if [ -n "$CPU_PCT" ]; then echo $((CPU_PCT * 1000)) > "$cpu/cpu.cfs_quota_us"; else echo -1 > "$cpu/cpu.cfs_quota_us"; fi
if [ -n "$MEM_MB" ]; then echo $((MEM_MB * 1024 * 1024)) > "$mem/memory.limit_in_bytes"; else echo -1 > "$mem/memory.limit_in_bytes"; fi
echo $$ > "$cpu/tasks"
echo $$ > "$mem/tasks"
exec "$@"
