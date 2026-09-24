#!/bin/sh
# The whole machine through the Pocket's real memory glue: nbajam_core against
# nbajam_mem, sdram_ctrl and sram_port with behavioural chips beyond the pins,
# and the ROM image pushed through the download port at the APF loader's rate.
# Pass it before a flash (METHODOLOGY 5.16); sim/run_machine.sh is the faster
# bench with the image preloaded.
#
#   sim/run_system.sh -frames N [-gap N] [-inputs f] [-snap a,b] [-out dir] [-wav f]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
rom="$root/.build/nbajam.rom"
[ -f "$rom" ] || { mkdir -p "$root/.build"; python3 "$root/tools/mra_build.py" \
    "$root/nbajam.mra" "$root/nbajam" "$rom" >/dev/null; }
MODS=$(ls "$root"/modules/cpu-mc6809/*.v "$root"/modules/sound-jt51/*.v "$root"/modules/sound-jt6295/hdl/*.v)
verilator --cc --exe --build -j "${JOBS:-8}" -O3 --x-assign fast --x-initial fast \
    -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET \
    -Wno-UNOPTFLAT -Wno-BLKANDNBLK -I"$root/modules/sound-jt6295/hdl" \
    --top-module tb_system_top -Mdir "$here/obj_system" $VFLAGS \
    "$root"/rtl/*.sv $MODS \
    "$root"/target/pocket/nbajam_mem.sv "$root"/target/pocket/sdram_ctrl.sv "$root"/target/pocket/sram_port.sv \
    "$here"/sdram_model.sv "$here"/sram_model.sv "$here"/tb_system_top.sv "$here"/tb_system.cpp \
    > "$here/obj_system.log" 2>&1 || { tail -40 "$here/obj_system.log"; exit 1; }
mkdir -p "$root/artifacts/system"
exec "$here/obj_system/Vtb_system_top" "$rom" -out "$root/artifacts/system" "$@"
