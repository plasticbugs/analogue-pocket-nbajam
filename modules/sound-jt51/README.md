# JT51 — Yamaha YM2151 (OPM) — Jose Tejada (@topapate)

- Upstream: https://github.com/jotego/jt51
- Vendored at commit `985a573`
- GPL-3.0-or-later (see `LICENSE`)

The 22 Verilog files listed by upstream's `hdl/jt51.qip`, which is the complete
synthesisable core. Upstream's testbenches (`ver/`), the C reference model
(`doc/opm.c`), the deprecated modules and the optional output filters are not
vendored; fetch the repository if you need them.

## Why this core

It is the YM2151 on the Williams D-11581 sound board in Arch Rivals, clocked at
3.579545 MHz. JT51 is FPGA-proven and is the YM2151 used across the MiSTer and
OpenGateware arcade cores, including Williams System 11 hardware.

It takes `cen` / `cen_p1` clock enables rather than a real clock, which suits
this project — everything runs from the single 40 MHz system clock with
generated enables. 3.579545 MHz needs a fractional accumulator, the same pattern
already used for both 68000s.

Licensing is straightforward: GPL-3.0-or-later composes with the GPL-3.0 this
project already inherits from fx68k.

## Cost

Measured with Quartus 18.1 for the Pocket's 5CEBA4F23C8: **1,870 combinational
ALUTs, 1,843 registers, 2,192 block memory bits (5 M10K), 1 DSP block**.
