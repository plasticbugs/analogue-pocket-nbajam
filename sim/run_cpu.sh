#!/bin/sh
# The CPU gate: rtl/tms34010.sv against MAME's own register and bus traces,
# on NBA Jam's program (the bench and the trace tools are Smash TV's).
#
#   sim/run_cpu.sh [trace-dir] [-n instructions]
#   sim/run_cpu.sh -live <seconds> [-n instructions]
#
# Traces come from tools/cpu_trace.sh (default .build/cputrace).  With -live
# two MAME runs write into named pipes and the bench reads them as they come.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$here/cpu"
dir="$root/.build/cputrace"
live=
if [ "$1" = "-live" ]; then live=$2; shift 2; fi
case "$1" in -*|"") ;; *) dir=$1; shift;; esac
rom="$root/.build/nbajam.rom"
[ -f "$rom" ] || { mkdir -p "$root/.build"; python3 "$root/tools/mra_build.py" \
    "$root/nbajam.mra" "$root/nbajam" "$rom" >/dev/null; }
[ -n "$live" ] || [ -f "$dir/trace_bus.bin" ] || { echo "no traces in $dir; run tools/cpu_trace.sh" >&2; exit 2; }
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    tb_public.vlt --top-module tb_cpu_top -Mdir obj \
    "$root"/rtl/tms34010.sv tb_cpu_top.sv tb_cpu.cpp > obj.log 2>&1 \
    || { tail -40 obj.log; exit 1; }
if [ -z "$live" ]; then
    exec ./obj/Vtb_cpu_top "$dir" "$rom" "$@"
fi
dir=$(mktemp -d "${TMPDIR:-/tmp}/njcpu.XXXXXX")
mkfifo "$dir/trace_bus.bin" "$dir/trace_reg.txt"
rm -rf "$root/.mame/nvram/nbajam"
INPUTS=${INPUTS:-$root/tools/inputs/play1.txt}; export INPUTS
TRACE_DIR="$dir" TRACE_N=2000000000 "$root/tools/mame.sh" \
    -autoboot_script "$root/tools/bus_trace.lua" -seconds_to_run "$live" >/dev/null 2>&1 &
p1=$!
CYCLES=1 TRACE_DIR="$dir" TRACE_FRAMES=100000000 "$root/tools/mame.sh" -debug -debugger none \
    -nvram_directory "$dir/nv2" \
    -autoboot_script "$root/tools/cpu_trace.lua" -seconds_to_run "$live" >/dev/null 2>&1 &
p2=$!
rc=0
./obj/Vtb_cpu_top "$dir" "$rom" "$@" || rc=$?
kill $p1 $p2 2>/dev/null || true
wait $p1 $p2 2>/dev/null || true
rm -rf "$dir"
exit $rc
