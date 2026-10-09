# The Analogizer

[Analogizer](https://github.com/RndMnkIII/Analogizer) is RndMnkIII's adapter
for the Pocket's cartridge slot. It gives analog video out of a VGA connector
(RGBS, RGsB, YPbPr, Y/C, and a scandoubled RGBHV) and takes native controllers
through SNAC adapters. Its wiki is the authority on the adapter itself:
[specifications](https://github.com/RndMnkIII/Analogizer/wiki/Analogizer-Specifications),
[how to configure it](https://github.com/RndMnkIII/Analogizer/wiki/Supported-Cores-and-How-to-Configure-Them).

This page covers what this core does with it, for the person using it and for
whoever changes the core next.

## For the player

**Settings are in the core's own menu**, under the game's other options,
like RndMnkIII's own "Pocket Menu" Analogizer cores (the wiki's list calls the
other kind, which reads a shared `analogizer.bin`, "Analogizer File"; this core
does not read that file). The Pocket remembers them for this core.

| entry | options |
|---|---|
| Analogizer | Off (the default), On, On, Pocket off (the picture goes to the CRT only) |
| Analogizer Video | RGBS, RGsB, YPbPr, Y/C NTSC, Y/C PAL, Scandoubler, Scandoubler 25% / 50% / 75%, Scandoubler HQ2x |
| SNAC Adapter | None, DB15, NES, SNES, PCE 2-button, PCE 6-button, PCE Multitap, DB15 Fast, SNES A,B<->X,Y, PSX Digital, PSX Digital Fast, PSX Analog, PSX Analog Fast |
| SNAC Assignment | the six below |
| Analogizer H Position | -24 to +6 dots; + moves the picture right |
| Analogizer V Position | -14 to +14 lines; + moves the picture down |

With **Analogizer** off the core behaves exactly as it did without Analogizer
support. The adapter itself is set up as its wiki's
[How to use it](https://github.com/RndMnkIII/Analogizer/wiki/How-to-use-it%3F)
says: SNAC switch in position A, 5 V into its USB-C port, the SCART cable's
audio jack in the Pocket's headphone socket.

**Position.** The two sliders move the picture on the CRT, in the core's
own dots and lines, for a set whose picture sits off centre (the first set
tried with Moo Mesa, another core with these sliders, showed it about 10
lines high).  They move the syncs,
not the picture, so nothing is cropped and every mode follows; the size is
still the set's to adjust.  0 is the board's own timing.

**Video.** The core sends the board's own signal: 400 × 254 visible, 15.81
kHz lines, 54.71 Hz, the timing a 15 kHz arcade monitor or a PVM expects
(some consumer sets will not hold 54.7 Hz; the scandoubled modes run at
the same frame rate). The board's picture sits far right in its line, 6
dots of blanking before hsync and 56 after, so H Position reaches further
left than right.

| mode | SOG switch | notes |
|---|---|---|
| RGBS | off | VGA-to-SCART or VGA-to-BNC |
| RGsB | on | R2/R3 adapters only |
| YPbPr | on | R2/R3 adapters only |
| Y/C NTSC, Y/C PAL | off | needs an active Y/C adapter on the VGA port |
| SC 0% / 25% / 50% / 75% / HQ2x | off | scandoubled for a VGA monitor: 31.6 kHz |

"On, Pocket off" turns the Pocket's own picture black while the CRT keeps
it.

**Controllers.** SNAC pads (DB15, NES, SNES, PC Engine 2/6-button and
multitap, PlayStation) replace the Pocket's controls according to the
**SNAC Assignment** chosen in the menu:

| assignment | player 1 | player 2 |
|---|---|---|
| SNAC P1 → Pocket P1 | SNAC 1 | the Pocket's own controls |
| SNAC P1 → Pocket P2 | Pocket | SNAC 1 |
| SNAC P1,P2 → P1,P2 | SNAC 1 | SNAC 2 |
| SNAC P1,P2 → P2,P1 | SNAC 2 | SNAC 1 |
| SNAC P1,P2 → P3,P4 | Pocket | dock 2 (SNAC goes to players 3 and 4, which this core does not have) |
| SNAC P1-P4 → P1-P4 | SNAC 1 | SNAC 2 |

This core plays the two-player games, so the first four rows are the useful
ones. The buttons map as they do on the Pocket: Y turbo (R also), X shoot
or block, A pass or steal (B also), select is coin, start is start. A
PlayStation pad in analog mode steers with its left stick.

**Cart power is on for everyone.** `core.json` declares the cartridge adapter,
so the Pocket powers the slot whether or not an Analogizer is in it. Do not
leave a game cartridge in the slot while this core runs.

**Not yet run on hardware with this core.** The same wrapper and module
have had one run in Moo Mesa (2026-10-08: the menu, and the picture on a
CRT, right). What has been checked here is listed under *What was
measured* below. Send problems with the adapter itself to the
Analogizer project.

## For the developer

### The pieces

| file | what |
|---|---|
| `target/pocket/analogizer/` | RndMnkIII's `openFPGA_Pocket_Analogizer` and what it instantiates, **verbatim** (modules/VENDOR.md has the commit). Its `analogizer.qip` is ours: only what is used. |
| `target/pocket/pocket_analogizer.sv` | the wrapper: clock hand-over, Y/C constants, SNAC → controller words. Core-agnostic; the same file in the template. |
| `target/pocket/core_top.sv` | `USE_ANALOGIZER`, the instance (after the bring-up panel), `key1..key4` in place of `cont1..4_key`, the bridge read at `0xF7xxxxxx`, the Pocket-screen blank, and the cart pins' idle levels when it is off. |
| `core_pll` `outclk_4` | the Analogizer's 48 MHz, `clk_sys / 2` in phase; in the SDC's PLL group. |
| `pkg/.../interact.json` | the entries above: ids 70–73, each a masked field of the word at `0xF7000000`, and 74–75, signed sliders at `0xF7000004` and `0xF7000008`. The enable and the Pocket-screen blank share one entry; Analogue's limit is 16 entries, and 20 with the data slots (`tools/check_json.py`) |
| `pkg/.../core.json` | `"cartridge_adapter": 0` (powers the slot) |
| `sim/run_analogizer.sh` | the bench (below) |
| `tools/check_json.py` | fails if an entry writes outside its mask, none sets the enable, a position slider is not signed within ±127, a data slot also writes `0xF7000000`, or the slot is not powered |

### The settings word

One 32-bit word at `0xF7000000`, the layout RndMnkIII's adapter module (1.4)
decodes. Each menu entry is a list with a mask that keeps every bit but its
own field (or fields), so the four entries share the word:

| bits | field | values |
|---|---|---|
| 4:0 | SNAC type | 0 none, 1 DB15, 2 NES, 3 SNES, 4 PCE 2-button, 5 PCE 6-button, 6 PCE multitap, 9 DB15 fast, 0xB SNES A/B↔X/Y, 0xC–0xF PS/2 keyboard (+ pad; not offered, the game has no use for it), 0x10/0x11 PSX digital (125/250 kHz), 0x12/0x13 PSX analog. 16 and up select the adapter's B wiring. |
| 5 | enable | 0: the port stays idle and nothing else applies |
| 9:6 | SNAC assignment | 0–5 as in the table above |
| 13:10 | video | 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5–9 scandoubler 0/25/50/75%/HQ2x |
| 14 | blank the Pocket screen | |
| 15 | OSD on the Analogizer output | not used by this core; no menu entry |

**Read-back.** The word is written as a number (the adapter module is told
`bridge_endian_little = 1`, so it does not byte-swap it as it would a file),
and `pocket_analogizer` keeps its own copy to read back, combinationally.
The Pocket's bridge (`io_bridge_peripheral.sv`) samples read data four clocks
after it presents the address and pulses `bridge_rd` only afterwards; the
adapter module updates its read-back on that pulse, so it would hand back
the *previous* read's value. The firmware merges a masked entry by
reading the word back (Analogue's interact.json docs: every entry not
`writeonly` is read back every frame), so that stale value would wipe the
other fields: in the bench, choosing a video mode turned the Analogizer off. RndMnkIII's menu
cores (Gauntlet) read the word back the same way, from a register.

**Picture position.** Two more words, each a whole signed slider value
(no mask): `0xF7000004` horizontal in dots, + right, and `0xF7000008`
vertical in lines, + down. `pocket_analogizer` reads the low 8 bits and
reads both words back, since the firmware reads every entry that is not
`writeonly` each frame. The adapter module stores them in a table it never
reads (`config_mem`). They move the syncs, not the picture: hsync n dots
earlier puts the picture n dots right, vsync n lines earlier puts it n
lines down. Earlier is built as a line (or frame) less n later: each sync
is re-made from the source's own rising edge after a delay counted in
dots, as wide as the source's, with the line and frame measured from the
source's syncs; the vsync's delay is whole lines, so its edges keep their
place in the line. RGB and blanking go through one clock later with them,
and at 0 each sync passes straight through.

A re-made sync starts only once it has been off at least as long as it is
on. The adapter module's `sync_fix` decides each sync's polarity afresh
every period, by whether the signal was high longer than low. A jump
between settings in one write (one "large" slider step, or a value loaded
at start) can put the next pulse just after the last one ends, and that
period reads as active-low: csync turned inside out for a frame (a line,
for hsync). With the rule such a jump skips one pulse instead.

The range is this core's, from the blanking NBA Jam programs into the
TMS34010 (`rtl/tunit_video.sv`: picture at dots 100–499 of 506 and lines
20–273 of 289, hsync at dots 0–43, vsync at lines 0–3): hsync can move 6
dots earlier before it meets the picture, and 28 later before the Y/C
colour burst (which ends about 28 dots after hsync does) would; vsync has
15 blank lines before it and 16 after. So -24..+6 dots and ±14 lines.
The bench fails if, at either end, csync is low while a dot is drawn: +8
dots fails it.

**The file scheme, not used here.** The adapter module 1.4 was written for
`analogizer.bin`, a file Pupdate and AnalogizerConfigurator write to
`/Assets/analogizer/common/`, loaded through a data slot at the same address.
It needs a data slot naming the file, a second platform id `analogizer`
that the slot's parameters point at, and the file on the card before the
adapter does anything. A player who has never heard of the file has an
Analogizer that stays dark, so this core uses the menu. A data slot at
`0xF7000000` would load the file over the menu's word; `tools/check_json.py`
refuses one.

### Clocks

`openFPGA_Pocket_Analogizer` runs its logic on `i_clk`, puts `video_clk` on the
cartridge pin that clocks the ADV7123, and assumes that is `i_clk` too. The
scandoubler halves the pixel period, so the clock has to be at least four
times the dot rate. The shipped Analogizer cores use 42.95–48 MHz. This core's
system clock is 96 MHz, which is more than the cart's level translators have
been asked to pass, so the PLL's spare output gives 48 MHz, in phase with
`clk_sys`. `pocket_analogizer` takes each pixel two system clocks after the dot
enable (`PIX_LAG`) into a holding register and hands it over with a toggle.
The Analogizer side picks it up two or three of its clocks later, well inside
the 12-clock dot (8 MHz, `clk_sys / 12`, as in Moo Mesa).

The Y/C encoder's subcarrier step and colour-burst window are computed in
integers from `CLK_HZ`. The reals used elsewhere lose the bits past 32 in some
tools, and MSX2's hand-typed NTSC step is a few counts off.

### Using SNAC in the game's inputs

`pocket_analogizer` outputs `key1..key4`, the Pocket's controller words with
SNAC pads put in place by the assignment. SNAC's bit order is the Pocket's
(0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 X, 7 Y, 8 L1, 9 R1, … 14 select,
15 start). They feed the `gamepad` helper in place of `cont1..4_key` (this
core reads the controllers nowhere else), so the game's input logic did not
change.

### What was measured

- `sim/run_analogizer.sh`: the wrapper and the vendored module at this core's
  raster and clocks, read at the cartridge pins as the DAC reads them.
  - With the menu at its defaults, every pin sits as on a core without the
    adapter, and the controller words pass through.
  - Every option of every Analogizer entry in the package's `interact.json`
    (32), set as the firmware sets a masked entry, read back the word as the
    bridge samples it, merged and written: the word, the adapter's copy and
    the enable each followed. With the adapter's own read-back in place of
    the wrapper's, the same run fails at the second entry.
  - RGBS: all 101,600 visible dots of a frame reach the DAC pins, in raster
    order, as their top six bits per channel, with 0 differing. Csync is one
    44-dot pulse a line.
  - Scandoubler: 578 lines per frame at 1518 clocks, half the core's 3036.
  - YPbPr and Y/C NTSC/PAL: no unknown on any pin for a frame.
  - All six SNAC assignments, the analog stick, and type "none" map as
    tabled.
  - Position, at both ends of the shipped sliders (+6,+14 and -24,-14):
    read back as written, the settings word untouched; at the pins csync
    moves by exactly 36 and 144 clocks (6 and 24 dots) and 14 lines each
    way, the picture is still all 101,600 dots with 0 differing, csync is
    never low while a dot is drawn, and the scandoubler still makes 578
    lines at 1518 clocks; back at 0, csync is where it started. +8 dots
    fails it (hsync inside the picture).
  - A jump written just after a pulse that puts the next one right after
    it (V +14 to +9, H +6 to -24, on a line with a picture): csync never
    low while a dot is drawn over three frames. (Without the off-time rule
    the same check fails in Moo Mesa's bench.)
  - The bench numbers its lines from the start of vblank (the core's line
    274), the same raster seen from where MAME starts the frame: its
    checks start just after a frame ends and need that point in the
    vertical blanking before the vsync.
  - The blank bit, and enable off again returning the port to idle.
- `sim/lint.sh`: the wrapper lints clean. The vendored files' warnings are
  dropped by path; their errors are not.
- The machine's own gates, unchanged by this (nothing in `rtl/` or the
  memory glue moved): `sim/run_mem.sh -quick` 0 wrong; `sim/run_video.sh`
  on frames 100, 1000 and 3000, 0 differing pixels.
- Quartus 18.1: compiles, every SDC constraint applied, no negative slack
  at any corner (worst setup +0.226 ns slow 0C, worst hold +0.070 ns fast
  0C, both clk_sys inside the machine). The Analogizer costs 1,611 ALMs
  (13,286 → 14,897, 81%), 16 RAM blocks (145 → 161 of 308) and 2 DSP
  blocks; worst setup went from +0.053 to +0.226 ns with the new fit.
  The first fit with it took the SDRAM capture (`dram_dq` → `dq_in`) to
  -0.056 ns hold at fast 0C, as the template's skeleton did; the SDRAM
  clock shift moved two VCO steps, 5.859 → 6.119 ns (the SDC says why not
  all the way to the 6.66 ns balance), and the capture now has +0.206 ns
  hold and +1.298 ns setup, the address/command outputs +2.567 setup and
  +3.139 hold at their worst corners.

**Not proven:** anything on hardware with this core; that the firmware writes a signed slider as a two's
complement word (Analogue's docs show signed sliders, no installed core
here uses one); and the SNAC serial protocols, which are
the adapter module's and are forced at its outputs in the bench rather than
driven over the pins. The Y/C and YPbPr encodings have no reference to compare
against, only a run without unknowns.

### Turning it off

Set `USE_ANALOGIZER = 0` in `core_top.sv`, remove `general[4]` from the PLL
group in the SDC (it would match nothing), and take the six menu entries
and `cartridge_adapter: 0` out of the JSON.
