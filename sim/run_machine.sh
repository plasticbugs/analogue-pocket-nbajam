#!/bin/sh
# The whole machine from reset on the real SDRAM controller, image preloaded.
#
#   sim/run_machine.sh -frames N [-inputs tools/inputs/play1.txt] [-snap a,b] [-out dir] [-wav f]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
rom="$root/.build/nbajam.rom"
[ -f "$rom" ] || { mkdir -p "$root/.build"; python3 "$root/tools/mra_build.py" \
    "$root/nbajam.mra" "$root/nbajam" "$rom" >/dev/null; }
MODS=$(ls "$root"/modules/cpu-mc6809/*.v "$root"/modules/sound-jt51/*.v "$root"/modules/sound-jt6295/hdl/*.v)
cd "$here/machine"
verilator --cc --exe --build -j "${JOBS:-8}" -O3 --x-assign fast --x-initial fast \
    -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET \
    -Wno-UNOPTFLAT -Wno-BLKANDNBLK \
    -I"$root/modules/sound-jt6295/hdl" \
    --top-module tb_machine_top -Mdir obj $VFLAGS \
    "$root"/rtl/*.sv $MODS \
    "$root"/target/pocket/sdram_ctrl.sv "$root"/sim/sdram_model.sv \
    tb_machine_top.sv tb_machine.cpp > obj.log 2>&1 || { tail -40 obj.log; exit 1; }
exec ./obj/Vtb_machine_top "$rom" "$@"
