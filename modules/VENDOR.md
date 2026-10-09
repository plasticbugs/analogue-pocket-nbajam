# Vendored modules

Third-party HDL cores copied into the tree — no submodules, so the build is
self-contained and reproducible. Each keeps its own LICENSE alongside.
`tools/vendor.sh <name>` fetches one from its upstream at a pinned commit,
with its licence; run it with no arguments to see what it knows about, or give
it a url and ref for anything else. `tools/gen_qip.sh` then lists everything
under `modules/` for Quartus.

| module | what it is | upstream | commit | licence |
|---|---|---|---|---|
| cpu-mc6809 | Greg Miller's cycle-accurate MC6809/E, with the Xenophobe core's change to run on the system clock with `cen_e`/`cen_q` | https://github.com/cavnex/mc6809 | via Xenophobe (ce86a8d) and Smash TV | BSD-style, `LICENSE.md` |
| sound-jt51 | YM2151, Jose Tejada (jotego) | https://github.com/jotego/jt51 `hdl/` | via Cadash/Xenophobe and Smash TV | GPL-3.0 |
| sound-jt6295 | OKI MSM6295, Jose Tejada (jotego) | https://github.com/jotego/jt6295 | 7d76b0be8cd8f85f3ae741178c9830b20e2071a1, via STUN Runner | GPL-3.0 |
| `target/pocket/analogizer/` | RndMnkIII's Analogizer adapter module (`openFPGA_Pocket_Analogizer` 1.4) and the 14 files it instantiates, verbatim, via the pocket-core-template; `analogizer.qip` is ours | https://github.com/RndMnkIII/MiraxPocket, `src/fpga/analogizer/` | 9dfdd2b9bec79fe5ea10e154a0613a0c9d4fe37f | GPL-3.0-or-later (the host core's); `hq2x.sv`, `scandoubler_2.v`, `yc_out_legacy.sv` carry their own GPL headers |

The Analogizer module lives under `target/pocket/` rather than `modules/`
because it is the Pocket's cartridge port, not the machine, and so that
`tools/gen_qip.sh` and the per-module lint do not sweep it in: `core.qip`
includes its own `analogizer.qip`, and `sim/lint.sh` lints it behind
`target/pocket/pocket_analogizer.sv` with a stand-in for its one VHDL file
(`sim/ps2_keyboard_stub.v`).  Left out: `scandoubler.v`, `scanlines.v`,
`yc_out.sv`, `psPAD_top.v`, `psx_control.v`, `csync.v`, `sync_fix.v` (also
defined inside the top file), `two_button_press_detector.v`, `uart_tx.v`
and `sine_lut.mem` -- nothing instantiates them.

For each module record what it is, its upstream repository and the exact
commit, its licence, and anything it needs that is not obvious — jt12's
`hdl/` has to be taken whole, for instance, because `jt12_top` instantiates
its ADPCM files outside a generate guard, so they must exist even when ADPCM
is disabled.

Written here rather than vendored, from MAME's device models:

* `rtl/tms34010.sv` — the TMS34010, **from the Smash TV core** (same author as
  this repository), cycle-paced to MAME's counts and held to MAME's bus and
  register traces there and here (`sim/run_cpu.sh`). NBA Jam's copy adds
  shift-register writes (FILL/PIXBLT/PIXT with DPYCTL.SRT), which Smash TV
  never needed.
* `rtl/tunit_video.sv` — adapted from Smash TV's `stv_video.sv`.
* `rtl/tunit_sound.sv` — the 6809/YM2151 plumbing is Smash TV's `stv_sound.sv`.
* `rtl/tunit_dma.sv`, `rtl/tunit_main.sv` — new, from `midtunit_v.cpp` and
  `midtunit.cpp`, checked by `sim/run_blit.sh` and the machine bench.

To update one: re-copy from upstream at the new commit and record it here.
