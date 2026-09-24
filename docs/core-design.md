# The core on the Pocket

How the board in `docs/hardware.md` maps onto the Pocket, and the budgets that
mapping has to meet. METHODOLOGY section 5.2. Figures marked *estimate* are
arithmetic from the constants below, not measurements; §5 is where they get
replaced by measured numbers.

## 1. Clocks

One system clock, **`clk` = 96 MHz**, as in the template and in STUN Runner,
whose TMS34010 this core reuses. Enables from `rtl/clk_enables.sv`:

| enable | ratio | real | board | error |
|---|---|---|---|---|
| `cen_gsp` | 25 / 384 (accumulator) | 6.25 MHz average | 50 MHz / 8 | 0 |
| `cen_vid` | ÷ 24 | 4.000 MHz | 8 MHz / 2 (34010 video clock) | 0 |
| `cen_pix` | ÷ 12 | 8.000 MHz | dot clock | 0 |
| `cen_snd` | ÷ 48 | 2.000 MHz | 6809E E clock (8 MHz / 4) | 0 |
| `cen_ym` | accumulator | 3.579545 MHz average | 3.579545 MHz | < 1 ppm |
| `cen_oki` | ÷ 96 | 1.000 MHz | 8 MHz / 8 | 0 |

`clk_vid` from the PLL is 8 MHz = `clk` / 12, so the dot clock is the board's
exactly and the refresh is the board's: 8e6 / (506 × 289) = **54.707 Hz**.
`pix_sync` pins `cen_pix` to `clk_vid` as the template does.

`pause` (the Pocket menu) freezes `cen_gsp`, `cen_snd`, `cen_ym`, `cen_oki`
and the blitter; `cen_vid` and `cen_pix` keep running so the picture stays up.
Because the 34010 generates the raster, its video counters run from
`cen_vid` independently of `cen_gsp` (as in STUN Runner's core).

## 2. Where each memory lives

| memory | size | Pocket resource | why | access |
|---|---|---|---|---|
| graphics ROM | 8 MB | SDRAM | too big for anything else | blitter: bursts, one source row at a time; CPU: rare single words |
| 34010 program | 1 MB | SDRAM | | single words behind the GSP's 1 KB instruction cache |
| OKI samples | 1 MB | SDRAM | | single bytes from jt6295, latency-tolerant |
| 6809 program | 128 KB | **SRAM** (the Pocket's 256 KB) | the sound CPU's rate is the DAC's sample rate (§5.3); a private, fixed-latency memory keeps it off the SDRAM arbiter | single bytes, ~3 clocks |
| VRAM | 1 MB (512K × 16-bit pixels) | SDRAM | 1 MB | blitter: burst writes a row at a time; scan-out: a 400-word burst a line; CPU: single words |
| work RAM | 512 KB | SDRAM | | single words |
| palette | 32K × 16 | block RAM, 64 M10K | scan-out reads one entry per dot | CPU port + video port |
| CMOS | 8K × 16 | block RAM, 16 M10K | small; saved as NVRAM | CPU |
| 6809 RAM | 8 KB | block RAM | | |
| line buffers, blitter row buffers | | block RAM | | |

Block RAM budget (*estimate*): palette 64, CMOS 16, 6809 RAM 7, GSP cache 3,
scan-out line buffers 2, blitter row buffers ~8, sound chips ~6: about 110 of
the 308 M10K.

## 3. The ROM image

`nbajam.mra` → `nbajam.rom`, 10,616,832 bytes, checked by
`tools/verify_rom.py` against MAME's regions. Each pair of image bytes is one
SDRAM word, first byte high; the word-wide regions are laid out so that the
SDRAM word is the little-endian word the chip reads.

| image bytes | region | goes to |
|---|---|---|
| 0x000000–0x7fffff | graphics | SDRAM byte 0x0000000 |
| 0x800000–0x8fffff | 34010 program | SDRAM byte 0x0800000 |
| 0x900000–0x9fffff | OKI | SDRAM byte 0x0900000 |
| 0xa00000–0xa1ffff | 6809 program | **SRAM** word 0x00000 (two bytes a word) |

The same constants are in `target/pocket/nbajam_mem.sv` and `sim/tb_mem.cpp`.

## 4. SDRAM map, clients and the arbiter

| SDRAM byte address | what |
|---|---|
| 0x0000000 | graphics ROM (8 MB) |
| 0x0800000 | 34010 program (1 MB) |
| 0x0900000 | OKI (1 MB) |
| 0x1000000 | VRAM (1 MB: pixel *p* at word 0x0800000 + *p*) — bank 1 |
| 0x2000000 | work RAM (512 KB) — bank 2 |

Random-access clients (`sdram_ctrl` c-ports, round robin):

0. the download (writes; runs only while the core is in reset);
1. the TMS34010 (program fetch on a cache miss, work RAM, VRAM, CPU reads of
   the graphics ROM) — one request at a time, stalls the GSP;
2. the OKI6295 (a byte every few µs at most).

The burst port has two users, arbitrated in `nbajam_mem.sv` with the owner
latched at grant (METHODOLOGY 5.17):

* the **scan-out line fetch** — 400 words a line (two bursts when the row
  wraps), deadline one line; first priority;
* the **blitter** — per destination row, a read burst of its source bits and a
  write burst of its pixels with byte enables marking the pixels actually
  written.

The download cannot stall: the template's 64-word FIFO stays.

## 5. Budgets — measured, not assumed

A line is 506 dots at 8 MHz = **6,072 clocks**.

| stage | budget (clocks) | ideal-memory bench | real-memory bench | hardware (panel) |
|---|---|---|---|---|
| scan-out line fetch | 6,072 a line | — | *estimate* ~950 (400 words at 2.25 + setup) | — |
| blitter, per frame | ≤ one frame (the vblank handler cancels a late blit) | — | `sim/run_blit.sh`, SDRAM otherwise idle: worst **46.6 %** (match-up screen, 2.85 clocks/pixel), play 26–36 %. With the controller's original 2-clock burst spacing: 69 % | — |
| GSP instruction rate | 6.25 M cycles/s | — | — | — |

MAME's own blitter timing is 41 ns a pixel (~3.9 clocks); the game waits for
each blit, so a blitter much slower than that slows the game, and one that
has not finished a frame's work by vblank is cut off (hardware.md §7.4). The
blitter reports its worst frame, saturating, on the panel (5.19).

The controller runs its bursts with `FAST_BURST`: one READ or WRITE a clock
(BL=1 allows it) instead of one every two, with a lookahead index `b_wpre`
so a client with a registered RAM can feed write data at that rate, and a
32-word chunk runs on in the open row unless a random client or the refresh
is waiting (their worst-case wait is unchanged). Off by default, so the
controller's proven behaviour is untouched for anything that does not ask.
Not yet proven on hardware.

## 6. Timing exceptions

None yet.

## 7. What is not cycle-exact, and why that is acceptable

* The blitter is faster or slower than the real one per blit; the game waits
  for completion, so only the total per frame matters, and that is measured.
* MAME draws a blit instantly; the RTL draws it over microseconds. Writes the
  CPU makes to VRAM while a blit runs can interleave differently. The game
  draws into the hidden page, so this is not visible.
* Skip mode is implemented unscaled only; scaled skip-mode blits (never seen
  in a capture) are counted in `stat_skipmode` rather than drawn exactly.
