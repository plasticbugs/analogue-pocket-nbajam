#!/bin/sh
# The sound board against MAME: replay MAME's command stream (tools/snd_log.lua)
# into rtl/tunit_sound.sv at MAME's times, write the output, compare.
#
#   sim/run_sound.sh cmds.txt seconds [outdir]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
cmds=$(abs "$1"); secs=$2; out=$(abs "${3:-$root/artifacts/audio}")
rom="$root/.build/nbajam.rom"
MODS=$(ls "$root"/modules/cpu-mc6809/*.v "$root"/modules/sound-jt51/*.v "$root"/modules/sound-jt6295/hdl/*.v)
verilator --cc --exe --build -j "${JOBS:-8}" -O3 --x-assign fast --x-initial fast \
    -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET \
    -Wno-UNOPTFLAT -Wno-BLKANDNBLK -I"$root/modules/sound-jt6295/hdl" \
    --top-module tb_sound_top -Mdir "$here/sound/obj" \
    "$root"/rtl/tunit_sound.sv $MODS "$here"/sound/tb_sound_top.sv "$here"/sound/tb_sound.cpp \
    > "$here/sound/obj.log" 2>&1 || { tail -30 "$here/sound/obj.log"; exit 1; }
mkdir -p "$out"
"$here/sound/obj/Vtb_sound_top" "$rom" "$cmds" "$secs" "$out"
