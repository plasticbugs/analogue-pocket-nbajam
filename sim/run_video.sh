#!/bin/sh
# Frozen-state gate for the scan-out: rtl/tunit_video.sv on the real SDRAM
# controller, each captured frame's picture compared with MAME's.
#
#   sim/run_video.sh [states-dir] [frame ...]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
dir=$(abs "${1:-$root/artifacts/states}")
[ $# -gt 0 ] && shift
cd "$here/video"
verilator --cc --exe --build -j "${JOBS:-8}" -O3 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
    -Wno-BLKSEQ -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET \
    --top-module tb_video_top -Mdir obj $VFLAGS \
    "$root"/rtl/tunit_video.sv "$root"/rtl/sdpram.sv "$root"/rtl/dpram_be.sv \
    "$root"/target/pocket/sdram_ctrl.sv "$root"/sim/sdram_model.sv \
    tb_video_top.sv tb_video.cpp > obj.log 2>&1 || { tail -40 obj.log; exit 1; }
frames=${*:-$(ls "$dir" | sed -n 's/^events_0*\([0-9]*\)\.txt$/\1/p' | sort -n)}
fail=0
for n in $frames; do
    a=$(printf '%s/state_%05d.bin' "$dir" $((n - 1)))
    b=$(printf '%s/state_%05d.bin' "$dir" "$n")
    printf 'frame %5d: ' "$n"
    if out=$(./obj/Vtb_video_top "$a" "$b"); then echo "$out" | tail -1
    else fail=1; echo "$out" | tail -1; echo "$out" | head -8; fi
done
[ $fail = 0 ] && echo PASS || { echo FAIL; exit 1; }
