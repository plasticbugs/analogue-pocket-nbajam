#!/bin/sh
# Frozen-state gate for the blitter: every captured frame's blits replayed
# through rtl/tunit_dma.sv on the real SDRAM controller, VRAM compared with
# MAME's.
#
#   sim/run_blit.sh image.rom [states-dir] [frame ...]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
rom=$(abs "$1"); dir=$(abs "${2:-$root/artifacts/states}")
[ -n "$rom" ] || { echo "usage: $0 image.rom [states-dir] [frame ...]" >&2; exit 2; }
shift; [ $# -gt 0 ] && shift
cd "$here/blit"
verilator --cc --exe --build -j "${JOBS:-8}" -O3 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
    -Wno-BLKSEQ -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET \
    --top-module tb_blit_top -Mdir obj $VFLAGS \
    "$root"/rtl/tunit_dma.sv "$root"/rtl/sdpram.sv \
    "$root"/target/pocket/sdram_ctrl.sv "$root"/sim/sdram_model.sv \
    tb_blit_top.sv tb_blit.cpp > obj.log 2>&1 || { tail -40 obj.log; exit 1; }
frames=${*:-$(ls "$dir" | sed -n 's/^events_0*\([0-9]*\)\.txt$/\1/p' | sort -n)}
fail=0
for n in $frames; do
    a=$(printf '%s/state_%05d.bin' "$dir" $((n - 1)))
    b=$(printf '%s/state_%05d.bin' "$dir" "$n")
    e=$(printf '%s/events_%05d.txt' "$dir" "$n")
    printf 'frame %5d: ' "$n"
    if out=$(./obj/Vtb_blit_top "$rom" "$a" "$e" "$b"); then echo "$out" | tail -1
    else fail=1; echo "$out" | tail -1; echo "$out" | head -6; fi
done
[ $fail = 0 ] && echo PASS || { echo FAIL; exit 1; }
