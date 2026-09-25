# First flash: what to do and what to read

For the person holding the Pocket. Keep this exact — it is read from while
someone decodes squares off a screen.

## Before flashing

- `sim/lint.sh` clean; `sim/run_mem.sh` passes at `-gap 8 -hold 4`.
- The whole-machine bench on the real memory glue boots.
- **`tools/check_frames.py` passes on three CONSECUTIVE frames of a STILL
  picture** — snapshot the boot screen at, say, 2500, 2520 and 2540 ms and run
  it on the three. If neighbours differ while frames two apart are identical,
  the core is emitting alternating fields. The Pocket's panel is OLED and
  holds the difference between the two images — as retention that fades, and
  with enough hours as wear that does not. A core shipped this way and left a
  ghost on a user's screen; nothing else on this list touches their hardware.
  Do not flash until it passes (METHODOLOGY 5.23).
- `tools/check_json.py pkg/pocket --active <W>x<H>` clean — the firmware
  refuses a bad `interact.json` with nothing but "General Error", and a
  `video.json` that disagrees with the core comes out as three separate-looking
  picture faults.
- `./build-local.sh compile`: no negative slack in any corner
  (`projects/output_files/*.sta.summary`), no ignored constraints.
- The ROM image's md5 matches the MRA's.

## On the card

`release/pocket/` onto the card root, with `cp -X` from macOS. The ROM image
goes in `Assets/nbajam/common/nbajam.rom`. Verify the bitstream's md5 on the
card.

## What a healthy first boot looks like

With no save file: after the load, a black screen with yellow and red text,
"NBA JAM REV 3.01 4/07/93 ... CMOS INVALID -- FACTORY SETTINGS RESTORED ...
ERRORS DETECTED -- ANY BUTTON TO CONTINUE" (about 1.5 s after the core
starts). Press any button: the title screen (the NBA JAM logo on a wooden
court), then the copyright screen, then attract. Once the game has written its
CMOS the core saves it (`Saves/nbajam/.../nbajam.sav`), and the next boot
skips the CMOS message.

The game's own test screens: menu -> **Service Switch** on, then Reset Core:
the test menu; **Monitor Patterns** there has the crosshatch and colour bars
to ask for before any photograph of gameplay (METHODOLOGY 5.18).

## The panel

Menu → **Bring-up: panel** (restore it first; see "The debug switches"). Four rows of 32 squares along the bottom edge of
the picture. Green is 1. Read each row from the end where row 0 shows
`1010 1010`.

| row | squares | meaning | healthy |
|---|---|---|---|
| 0 | 1–8 | alignment marker | `1010 1010` — if not, stop: the reading is misaligned |
| 0 | 9–16 | frame counter | changing |
| 0 | 17 | PLL locked | 1 |
| 0 | 18 | memory ready | 1 |
| 0 | 19 | downloading | 0 |
| 0 | 20 | all slots complete | 1 |
| 0 | 21 | loaded | 1 |
| 0 | 22 | core in reset | 0 |
| 0 | 23 | SRAM self-test finished | 1 |
| 0 | 24 | blitter busy | flickering during play |
| 0 | 25–32 | IN1 bits 7–0, active low: 25 coin 3, 26 service credit, 27 start 2, 28 service (test), 29 tilt, 30 start 1, 31 coin 2, 32 coin 1 | `1111 1111` with nothing pressed |
| 1 | 1 | the CPU met an instruction it does not implement | 0 |
| 1 | 2–32 | the TMS34010's program counter (bits 30–0): live, or frozen where it first met that instruction | changing, in `0xFF8xxxxx`–`0xFFFxxxxx` |
| 2 | 1–8 | scan-out lines whose SDRAM fetch was late (saturates at 255) | 0 |
| 2 | 9–16 | scaled skip-mode blits (not drawn exactly) | 0 |
| 2 | 17–24 | sound-ROM stalls of the 6809 | 0 or 1 (one is seen at power-up in simulation) |
| 2 | 25–32 | the 6809's address, high byte | changing |
| 3 | 1–16, 17–32 | SRAM self-test | `1010 0101 0101 1010`, `0101 1010 1010 0101` |

Row 3 proves the SRAM answers; it does NOT prove the sound program in it is
intact. The first build's test overwrote the 6809's reset vector and still
read a pass (log, below). The test now puts back what it overwrote, and
`sim/run_mem.sh` checks all 128 KB of the program after it.

## The debug switches

**Not on the release menu.** They were taken off `interact.json` once the
core worked; the logic is still in `core_top.sv` and every switch's
all-clear value is the tested setting. To debug on hardware, restore their
entries (ids 90-94) from commit `684fce7`'s `interact.json` -- the panel
(id 90) included -- and the split burst list (reads and writes separately)
from commit `f86c875`.

Since 0.2.0 the all-clear bursts are **writes one word a clock, reads one
every two**: the only combination that is both clean and fast enough on
hardware (see the log).

| menu item | what it does | healthy setting |
|---|---|---|
| **SDRAM bursts** | how fast the graphics memory streams: Normal (a word every 2 clocks), Fast (every clock), Slow (every 5) | Normal (default) |
| **SDRAM read late** | the label is inverted: ticked samples the memory's data one clock **earlier** | unticked |
| **SRAM read late** / **SRAM long writes** | stretch the SRAM timing | unticked |

## If it is wrong

| symptom | look at |
|---|---|
| black, counter running, PC stuck or wandering outside `0xFF8xxxxx` | the image in SDRAM — rerun `sim/run_mem.sh`; section 5.16; then **Bring-up: SDRAM** switches and the PLL phase (SDC, 5.20) |
| row 1 square 1 lit | the PC shown is the unimplemented instruction: tell Claude the 31 bits |
| row 3 not the pattern, silence | **SRAM read late / long writes**; then the SRAM port |
| row 3 a pass, silence | the sound program in the SRAM; row 2 squares 25–32 should change |
| colours wrong, shapes right | **SDRAM bursts**: try Slow, then Normal; then Fast with **SDRAM read late** ticked |
| row 2 squares 1–8 non-zero, or horizontal tearing | the scan-out fetch is losing to the blitter/CPU on the SDRAM |
| graphics missing only in busy scenes | the blitter is not finishing by vblank and the game cancels it (hardware.md 7.4) |
| garbled picture | ask for the service-mode test pattern first; section 5.18 |
| glitches only while playing, gone in the menu | something the CPU shares with the video; section 5.17 |
| menu restarts the game | `pause` has reached a reset; section 5.5 |

## Log

Date, build md5, what was seen, what it ruled out. One line each. The theories
that died belong here as much as the one that lived.

- 2026-09-24, `6f7d0f99…` (compile 8): boots, plays. **Colours wrong,
  shapes okay-ish** with fast bursts; **perfect with SDRAM slow bursts** —
  the fast (one word a clock) burst read is unreliable on hardware at the
  default capture phase; the logic is right. **Silent**, apart from pops and
  clicks, in attract and gameplay: the SRAM self-test wrote 0x1fffe/0x1ffff
  through a 16-bit port, landing on the 6809's NMI/RESET vectors after the
  download (reproduced in `sim/run_mem.sh`: ROM bytes 1FFFC–1FFFF damaged).
- 2026-09-24, `6f7d0f99…` again (the card had not been updated): with the
  Normal/Fast/Slow list absent, only "SDRAM slow bursts" gave a clean
  picture; still silent. Says nothing about compile 10.
- 2026-09-24, `05629f94…` (compile 10): **"it's perfect"** — picture and
  sound. The SRAM self-test fix is confirmed on hardware.
- 2026-09-24, `198afc75…` (compile 12, Tournament Edition added): both games
  run; TE looks right. Frame drops in TE play with a basket in view.
  Measured (sim/run_machine.sh, TE, frames 1600-2599): MAME flips the page on
  975 frames of 1000, this core with Normal bursts on 796 -- half rate at
  2201-2233, blitter busy ~94% of every frame.
- 2026-09-24, `d6a02c5b…` (compile 13, test build, reads and writes split on
  the menu): **"Fast writes only" -- clean and no frame drops.** Writes at one
  word a clock are sound on the Pocket; reads at that pace are what garbled
  the palette. Fast with the earlier read capture was not reported. The same
  setting makes the original NBA Jam run smoothly too (the user's report).
