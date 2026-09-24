#!/bin/sh
# Capture the TMS34010's bus and register traces from MAME for sim/run_cpu.sh.
# Two runs, because the debugger's disassembler would otherwise show up in the
# bus trace (see tools/cpu_trace.lua).
#
#   tools/cpu_trace.sh [dir] [frames] [start-frame]
#
# With a start frame the traces begin there instead of at reset and
# ioregs.txt carries the CPU's I/O registers at that instant, which is what
# lets sim/run_cpu.sh check any window of the game in seconds.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:-$root/.build/cputrace}
frames=${2:-40}
start=${3:-0}
secs=$(( (start + frames) / 54 + 3 ))
rm -rf "$root/.mame/nvram/nbajam"
INPUTS=${INPUTS:-$root/tools/inputs/play1.txt}; export INPUTS
mkdir -p "$dir"
rm -f "$dir/trace_bus.bin" "$dir/trace_reg.txt" "$dir/ioregs.txt"
# each run starts from a fresh CMOS, as every capture here does
START_FRAME="$start" TRACE_DIR="$dir" TRACE_N=$(( frames * 120000 )) "$root/tools/mame.sh" \
    -autoboot_script "$root/tools/bus_trace.lua" -seconds_to_run "$secs" >/dev/null 2>&1 || true
rm -rf "$root/.mame/nvram/nbajam"
CYCLES=1 START_FRAME="$start" TRACE_DIR="$dir" TRACE_FRAMES="$frames" "$root/tools/mame.sh" -debug -debugger none \
    -autoboot_script "$root/tools/cpu_trace.lua" -seconds_to_run "$secs" >/dev/null 2>&1 || true
ls -la "$dir" | tail -3
