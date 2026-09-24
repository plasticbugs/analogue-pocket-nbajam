# MC6809/MC6809E — Greg Miller

Cycle-accurate Motorola MC6809 / MC6809E in Verilog.

- Upstream: https://github.com/cavnex/mc6809
- Vendored at commit `17e94a6`
- Copyright (c) 2016, Greg Miller

Only `mc6809i.v` (the core) and `mc6809e.v` (the MC6809E wrapper, which exposes
the external **E** and **Q** clocks) are vendored here. The upstream repository
also carries GODIL board projects, devboard projects and documentation, none of
which this core needs.

## Which license

Upstream offers a choice of two licenses and states **"You must select one."**

We **select the standard BSD license** — the three-clause form reproduced in
`LICENSE.md` — because this project redistributes its source. The alternative
"Modified BSD License" upstream offers forbids redistribution in source form,
which is incompatible with publishing this repository.

BSD-3-Clause is compatible with the GPL-3.0 that this project as a whole is
distributed under (see the repository `LICENSE`), so nothing about the overall
licensing changes. The clauses that bind us are: retain the copyright notice
and disclaimer (they are in the source headers and in `LICENSE.md`), and do not
use the author's name to endorse this project.

## Why this core

It is used here for the MC6809E on the Williams D-11581 sound board in Arch
Rivals. The author validated it not only in simulation but by building a
GODIL-40 adapter, removing the physical 6809 from real Williams arcade boards
and running the games — Defender, Robotron, Joust, Sinistar, Splat, Stargate,
Bubbles — plus a Vectrex and a TRS-80 CoCo 3. That is the same family of
hardware this core targets.

The D-11581 clocks it at 8 MHz / 4 = 2 MHz on E, which is exactly 40 MHz / 20,
so the clock enables divide the system clock with no fractional accumulator.

## Local modifications

Both are marked `LOCAL MODIFICATION` in `mc6809i.v`. The BSD licence permits
modification; the copyright notice and disclaimer are retained.

**1. Power up with no NMI pending.** `NMILatched` is written only by an
asynchronous block, so with no initial value it powers up as 0 = "NMI pending"
and the CPU takes a spurious NMI on its first instruction. Nothing in the reset
path can clear it: `NMIClear` is held low during reset, and the NMI mask is
released on the first non-reset cycle because reset itself changes S. Found by
tracing this board's bus at power-up — the 6809 pushed twelve bytes to
`0xFFFC..0xFFF1` and vectored through `0xFFFC` before executing any of the
firmware.

**2. `SEX` sets its condition codes.** Upstream sign-extends B into A but leaves
CC untouched. Per the MC6809 datasheet, SEX sets N from the result's sign, Z if
the 16-bit result is zero, and clears V. MiSTer's copy of this core carries an
equivalent fix.

## Cost

Measured with Quartus 18.1 for the Pocket's 5CEBA4F23C8: **2,247 combinational
ALUTs, 291 registers**. Most of the area is combinational — it is a deliberately
unpipelined, cycle-accurate state machine rather than a compact one.
