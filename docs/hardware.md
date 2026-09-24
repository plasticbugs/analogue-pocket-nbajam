# The board — Midway T-unit, as NBA Jam uses it

Written from MAME **0.288** (`ref/mame/`, fetched verbatim from tag
`mame0288`) and from MAME runs of the game (`tools/probe_board.lua`, log in
`artifacts/probe/`). Files:

| file | what it gives |
|---|---|
| `src/mame/midway/midtunit.cpp` | memory map, inputs, machine config, ROM layout |
| `src/mame/midway/midtunit_m.cpp` | CMOS, protection, sound latch, reset |
| `src/mame/midway/midtunit_v.cpp`, `.h`, `.ipp` | VRAM, control latch, DMA blitter, scan-out |
| `src/mame/shared/williamssound.cpp` | the Williams ADPCM sound board |
| `src/devices/cpu/tms34010/*` | the TMS34010 (display timing, interrupts, SRT) |

MAME's `nbajam` is rev 3.01 (4/07/93), `init_nbajam`, `tunit_adpcm`.

## 1. Parts and clocks

| part | type | clock | notes |
|---|---|---|---|
| main CPU | TMS34010 | 50 MHz CLKIN, 6.25 MHz machine cycle (÷8) | bit-addressed, 16-bit bus; also the display controller |
| video | TMS34010 timing + VRAM + 32K palette | video clock 4 MHz (`PIXEL_CLOCK = 8 MHz/2`), 2 pixels per video clock → dot clock **8 MHz** | HTOTAL 506, VTOTAL 289 → **54.7068 Hz**; 400 × 254 visible |
| blitter | Midway DMA (in `midtunit_v`) | — | MAME: 41 ns per pixel drawn, then DMA IRQ |
| sound CPU | MC6809E | 2 MHz (8 MHz / 4) | on the Williams ADPCM board |
| FM | YM2151 | 3.579545 MHz | IRQ → 6809 FIRQ; routed ×0.10 |
| DAC | AD7524 (8-bit) | written by the 6809 | routed ×0.10 |
| ADPCM | OKI MSM6295 | 1 MHz (8 MHz / 8), pin 7 high (rate ÷132) | routed ×0.15; MAME: "clock & pin 7 not verified" |
| CMOS | 16 KB battery RAM | — | MAME `nvram`, default all zero |

Every clock is an exact divisor of 96 MHz except the TMS34010 cycle
(96/15.36) and the YM2151: 8 MHz dot = 96/12, 4 MHz video = 96/24,
2 MHz 6809 = 96/48, 1 MHz OKI = 96/96.

Measured display registers (identical at every 250th frame from 250 to 4750):

| reg | value | meaning |
|---|---|---|
| HESYNC | 0x0015 | |
| HEBLNK | 0x0032 | picture starts at video clock 50 = dot 100 |
| HSBLNK | 0x00fa | picture ends at video clock 250 = dot 500 |
| HTOTAL | 0x00fc | 253 video clocks = 506 dots |
| VESYNC | 0x0003 | |
| VEBLNK | 0x0014 | first picture line 20 |
| VSBLNK | 0x0112 | picture ends at line 274 |
| VTOTAL | 0x0120 | 289 lines |
| DPYCTL | 0xf010 | ENV, NIL, DXV, SRE clear; see §7 |
| DPYSTRT | 0xfffc / 0xeffc | alternates: page flip between two 256-line halves |
| DPYINT | 0x0112 | display interrupt at line 274 (start of vblank) |
| CONTROL | 0x002c | |
| INTENB | 0x0404 | DIE + X2E (INT2 is not driven on this board) |
| PSIZE | 0x0008 | 8-bit pixels (the CPU's view of VRAM, §7.1) |

**Audio pacing.** Music tempo comes from the YM2151's timers (its IRQ is the
6809's FIRQ); the OKI runs from its own clock. The DAC is written by the 6809
in software, so any DAC samples it plays are paced by the 6809 and the FIRQ
rate. The 6809's execution rate matters for the DAC only; METHODOLOGY §5.3
applies to that one channel.

## 2. Memory map — TMS34010

The TMS34010 addresses **bits**. MAME's address map is in bit addresses; a
16-bit word is at `A >> 4`. "words" below are 16-bit.

| bit range | size | what | R/W | notes |
|---|---|---|---|---|
| 0000_0000–003f_ffff | 256K words | VRAM, through the bank latch (§7.1) | RW | each CPU word = two 16-bit pixels' low or high bytes |
| 0100_0000–013f_ffff | 512 KB | work RAM | RW | |
| 0140_0000–0141_ffff | 8K words | CMOS (16 KB), full 16-bit | RW | writes are always allowed (MAME `if (1)`); saved to NVRAM |
| 0148_0000–014f_ffff | — | CMOS write enable | W | MAME records it and ignores it |
| 0160_0000–0160_000f | 1 word | IN0 | R | |
| 0160_0010–0160_001f | 1 word | IN1 | R | |
| 0160_0020–0160_002f | 1 word | IN2 | R | |
| 0160_0030–0160_003f | 1 word | DSW | R | |
| 0180_0000–0187_ffff | 32K words | palette, xRGB555 | RW | |
| 01a8_0000–01a8_00ff | 16 words | DMA blitter registers | RW | §7.3 |
| 01b0_0000–01b0_001f | 1 word | T-unit control latch | W | bit 5 VRAM bank; bit 7 gfx bank (large-ROM boards only — not NBA Jam) |
| 01b1_4020–01b2_503f | — | **protection** (§4.2) | RW | installed by `init_nbajam` over the rest of the map |
| 01d0_0000–01d0_001f | 1 word | sound status | R | §5 |
| 01d0_1020–01d0_103f | 1 word | sound command / reset | RW | §5 |
| 01d8_1060–01d8_107f | — | watchdog | W | MAME's watchdog has no timeout configured: ignored |
| 01f0_0000–01f0_001f | 1 word | control latch (second decode) | W | written once at boot, 0xfff8 |
| 0200_0000–07ff_ffff | — | graphics ROM, CPU read | R | word `o`: bank `(o >> 21) & 1` × 0x400000 + `(o & 0x1fffff) * 2` bytes, little-endian |
| c000_0000–c000_01ff | — | TMS34010 I/O registers | RW | internal |
| ff80_0000–ffff_ffff | 1 MB | program ROM | R | also mirrored at 1f80_0000 (MK uses it) |

Unmapped reads return all ones (`unmap_value_high`).

## 3. Inputs and DIP switches

All active low. From `INPUT_PORTS_START( nbajam )`.

| port | bit | function |
|---|---|---|
| IN0 | 0–3 | P1 up, down, left, right |
| | 4 | P1 Shoot / Block (BUTTON2) |
| | 5 | P1 Pass / Steal (BUTTON3) |
| | 6 | P1 Turbo (BUTTON1) |
| | 8–11, 12, 13, 14 | P2 the same |
| IN1 | 0, 1 | coin 1, coin 2 |
| | 2 | start 1 |
| | 3 | tilt (slam) |
| | 4 | service (test) |
| | 5 | start 2 |
| | 6 | service 1 (service credit) |
| | 7, 8 | coin 3, coin 4 |
| | 9, 10 | start 3, start 4 |
| | 11, 12 | volume down, up |
| IN2 | 0–6 / 8–14 | P3 / P4, laid out as IN0 |
| DSW | 0 | Test Switch (1 = off) |
| | 1 | Powerup Test (0 = off, default) |
| | 5 | Video Clips (1 = on, default) |
| | 6 | Dollar Bill Validator (1 = not present) |
| | 7 | Players (1 = 4, default) |
| | 9:8 | Coin counters (11 default) |
| | 11:10 | Country (11 USA) |
| | 14:12 | Coinage (111 = "1"); 000 free play |
| | 15 | Coinage source (0 = CMOS, default) |

MAME's default DSW, from `mame -listxml nbajam`: **0x7ffd** (everything off
or "1" except Powerup Test = 0 and Coinage Source = CMOS).

A fresh CMOS stops the game at "CMOS INVALID — FACTORY SETTINGS RESTORED …
ANY BUTTON TO CONTINUE". Two credits start a game at the default settings.

## 4. Interrupts and protection

### 4.1 Interrupts

| source | TMS34010 input | enabled | how acknowledged |
|---|---|---|---|
| display interrupt, VCOUNT == DPYINT (274) | DI (internal) | yes (INTENB.DIE) | clear INTPEND.DI |
| DMA done | INT1 (`set_inputline(m_maincpu, 0)`) | **no** — polled in INTPEND | a write to DMA register 1 clears the line |
| — | INT2 | enabled, never driven | |

MAME asserts the DMA IRQ `41 ns × pixels` after the command write (§7.3) and
clears DMA_COMMAND bit 15 at the same moment.

### 4.2 Protection (`nbajam_prot_r/w`)

Any write in 01b1_4020–01b2_503f loads a five-word queue:

```
idx   = (word_offset >> 6) & 0x7f        word_offset = (A - 0x01b14020) >> 4
val   = nbajam_prot_values[idx]          (128 × u32 table in midtunit_m.cpp)
queue = { data, val[31:24] << 9, val[23:16] << 9, val[15:8] << 9, val[7:0] << 9 }
index = 0
```

Each read returns `queue[index]` and advances index up to 4 (it then sticks).
Observed: 896 writes over 4800 frames, all during boot (frame 153).
**Note:** MAME's `word_offset` is relative to the start of the installed range
(`0x1b14020`), which is how `read16smo`/`write16sm` handlers receive offsets.

### 4.3 Sound-board protection

`init_nbajam` installs 43 bytes of RAM at 6809 0xfbaa–0xfbd4, over the ROM.
The real board has a small RAM (or PAL) there; the game's sound code relies on
it.

## 5. Main CPU to sound CPU

`sound_w` (01d0_1030; offset 0 is ignored), full 16-bit writes only:

* `reset_write(~data & 0x100)`: bit 8 **low holds the 6809 in reset** (and
  resets the board: ROM bank 0, interrupts cleared); bit 8 high releases it.
* `write(data & 0xff)`: the low byte goes to the command latch **and asserts
  the 6809 IRQ** (bit 9 of the parameter is always zero here).

The 6809 reads the latch at 0x3000 (mirror 0x3fff), which clears its IRQ; the
"interrupt state" bit stays set 10 µs longer.

`sound_state_r` (01d0_0000) is **faked by MAME**: after each command write it
returns 0 for the next 128 reads, then 0xffff. `sound_r` returns 0xffff.
Open question §10.1: what the real status bit is.

Observed commands (4800 frames of boot and attract): `fe00`, `ff00` (reset
pulse at boot and at frame 150), `ff92`, then `ffaa`/`ffa4` and a
`0001`/`0000` pair that holds the sound CPU in reset from frame 1511 to 3503.

## 6. Sound board (Williams ADPCM)

6809 map (`williams_adpcm_map`):

| range | what |
|---|---|
| 0000–1fff | 8 KB RAM |
| 2000 (mirror 03ff) | W: ROM bank select, `data & 7` |
| 2400–2401 (mirror 03fe) | YM2151 address / data (R: status) |
| 2800 (mirror 03ff) | W: DAC |
| 2c00 (mirror 03ff) | OKI6295 R/W |
| 3000 (mirror 03ff) | R: command latch (clears IRQ) |
| 3400 (mirror 03ff) | W: OKI bank, `data & 7` |
| 3c00 (mirror 03ff) | W: talkback latch (not readable by the main CPU in MAME) |
| 4000–bfff | banked ROM: region `0x10000 + bank * 0x8000` |
| c000–ffff | fixed: region `0x10000 + 0x4000 + 7 * 0x8000` = `0x4c000` |
| fbaa–fbd4 | protection RAM (§4.3), overrides the ROM |

The region `adpcm:cpu` is 0x50000 bytes: `u3` (128 KB) at 0x10000 and again
at 0x30000. So bank *b* is `u3[(b & 3) * 0x8000]`, and the fixed page is
`u3[0x1c000..0x1ffff]`.

OKI address space (256 KB): 00000–1ffff is the bank, 20000–3ffff is fixed at
`oki` region 0x60000. Banks (region offsets): 0 → 0x40000, 1 → 0x40000,
2 → 0x20000, 3 → 0x00000, 4 → 0xe0000, 5 → 0xc0000, 6 → 0xa0000,
7 → 0x80000. `u12` is at 0x00000, `u13` at 0x80000, each 512 KB.

Mixing: YM2151 ×0.10 (both channels to mono), DAC ×0.10, OKI ×0.15; the board
output is mono.

## 7. Video

### 7.1 VRAM

`m_local_videoram` is 512K × 16 bits: each entry is one pixel, `color[15:8] |
data[7:0]`, and the displayed value is `pixel & 0x7fff`, an index into the
32K-entry palette. The display and the blitter use the first 256K (512 rows
of 512); the CPU can reach all 512K.

CPU view (word offset `o` in 0000_0000–003f_ffff, i.e. `o = A >> 4`):
pixels `2o` and `2o+1`.

* **bank 1** (control bit 5 set): read `{p[2o+1][7:0], p[2o][7:0]}`; write
  byte 0 → `p[2o] = data[7:0] | DMA_PALETTE[7:0] << 8`, byte 1 →
  `p[2o+1] = data[15:8] | DMA_PALETTE[15:8] << 8` (whole pixels).
* **bank 0**: read `{p[2o+1][15:8], p[2o][15:8]}`; write byte 0 →
  `p[2o][15:8] = data[7:0]`, byte 1 → `p[2o+1][15:8] = data[15:8]` (colour
  bytes only).

Shift-register transfers copy 1024 pixels (two rows) at pixel `address >> 3`
to/from the TMS34010's shift register — see §7.4, the game uses them to clear
a page every frame.

### 7.2 Scan-out

`scanline_update`: for each line, `src = vram[(rowaddr << 9) & 0x3fe00]`,
starting at column `coladdr << 1`, wrapping at 512 (`& 0x1ff`), for dots
HEBLNK·2 … HSBLNK·2 − 1; the value is `pixel & 0x7fff` through the palette
(xRGB555 → 8-bit by MAME's `pal5bit`, i.e. `(v << 3) | (v >> 2)`).
`rowaddr`/`coladdr` come from the TMS34010's DPYADR/DPYSTRT logic.

### 7.3 DMA blitter

Registers (16 words at 01a8_0000; register *r* at `0x01a80000 + 16r`). When
`CONFIG` (reg 15) bit 5 is 0, registers 12 and 13 write the pseudo-registers
LEFTCLIP / RIGHTCLIP instead of TOPCLIP / BOTCLIP. Reads of register 0 return
register 1.

| reg | name | bits used |
|---|---|---|
| 0 | LRSKIP | start/end skip (below) |
| 1 | COMMAND | writing it starts or cancels a blit |
| 2, 3 | OFFSET lo, hi | source **bit** address in the graphics ROM |
| 4 | XSTART | `& 0x3ff` |
| 5 | YSTART | `& 0x1ff` |
| 6 | WIDTH | `& 0x3ff` |
| 7 | HEIGHT | `& 0x3ff` |
| 8 | PALETTE | `& 0x7f00` for blits; the full word for CPU VRAM writes |
| 9 | COLOR | `& 0xff` |
| 10, 11 | SCALE X, Y | 8.8 step; 0 means 0x100 |
| 12, 13 | TOP/BOTCLIP (`& 0x1ff`) or LEFT/RIGHTCLIP (`& 0x3ff`) | |
| 14 | test | NBA Jam writes only 0 |
| 15 | CONFIG | bit 5 selects the clip register bank |

COMMAND bits: 15 start; 14:12 bpp (0 = 8); 11:10 postskip; 9:8 preskip;
7 skip-mode enable; 6 start/end-skip format; 5 Y flip; 4 X flip; 3:0 pixel
op: bit 0 zero pixels copied, bit 1 non-zero copied, bit 2 zero pixels as
COLOR, bit 3 non-zero as COLOR. MAME's table (`INIT_TEMPLATED_DMA_DRAW_GROUP`):

| op | zero pixel | non-zero pixel |
|---|---|---|
| 0 | — (nothing drawn) | — |
| 1 | copy (`pal`) | skip |
| 2 | skip | copy (`pix | pal`) |
| 3 | copy | copy |
| 4, 5 | COLOR | skip |
| 6, 7 | COLOR | copy |
| 8, 10 | skip | COLOR |
| 9, 11 | copy | COLOR |
| 12–15 | COLOR | COLOR |

`COLOR` writes `pal | color`; `copy` writes `pixel | pal`. Bit 6: if set,
startskip = LRSKIP[7:0], endskip = LRSKIP[15:8]; else startskip = 0,
endskip = LRSKIP (whole word). Op 0xc: the source offset is forced to 0.
Offsets ≥ 0x2000000 have 0x2000000 subtracted (small-ROM board); ≥ 0xf8000000
lose 0xf8000000; ≥ 0x10000000 afterwards → no draw, but the IRQ still fires
at once.

The draw loop is `dma_draw<bpp, xflip, skip, scale, zero, nonzero>` in
`midtunit_v.cpp`; it is the specification, written out as numbered steps in
the reference renderer (`tools/dma_model.py`). Points that matter:

1. Source pixels are read LSB-first from a little-endian byte stream:
   `(rom[o>>3] | rom[(o>>3)+1] << 8) >> (o & 7) & mask`.
2. Destination pixel `vram[sy * 512 + sx]` with `sx` wrapped to 10 bits and
   `sy` to 9: `sx` of 512–1023 writes into the *next* row.
3. Horizontal clip is per pixel (`leftclip ≤ sx ≤ rightclip`), vertical per
   row (`topclip ≤ sy ≤ botclip`); a clipped row still advances the source.
4. X flip decrements `sx`; Y flip decrements `sy`.
5. Scaling steps the source by `xstep`/`ystep` in 8.8.
6. Completion: DMA_COMMAND bit 15 cleared and INT1 asserted
   `41 ns × pixels` after the start, where `pixels = width × height`
   unscaled or `(width·256/xstep) × (height·256/ystep)` scaled.

**What NBA Jam issues** (4800 frames, boot + attract + demo play; 685,974
blits): commands 8002, 8012, 9002, a002, b000, b002, c002, d002, e000, e002,
e012, f000, f002, f008, f012. So: op 2 (non-zero copy) nearly always, op 0
(no draw: pure delay) and op 8 (non-zero as colour) rarely; **X flip
yes, Y flip never, bit 6 never**; every bpp 1–8. **Skip mode is used**
(0x8588 / 0x8582, unscaled, pre/post skip 1) by the match-up screen's player
portraits — the first probe never reached that screen, and this line said
"never" until the RTL bench counted two a frame there. Scaling:
not yet measured (§10). Load: mean 144K pixels per frame, **max 326,270**, max
223 blits in a frame.

### 7.4 The frame, as the game runs it

Measured in MAME (`tools/dump_state.lua`, every I/O write logged with the
beam's line), identical in attract, menus and gameplay:

1. VCOUNT = DPYINT = 274 (start of vblank): the display interrupt. The
   handler (PC ff8262f0) first waits for any blit still running — polling
   DMA_COMMAND bit 15 up to 0xcb2 times — and **aborts it by writing 0 to
   DMA_COMMAND** if it has not finished. An earlier loop (ff826440) does the
   same with 0x1964 iterations. The RTL must honour a write of 0 as a cancel.
2. It writes DPYCTL = 0x6810 (SRT on, **ENV off**), and with SRT on does
   `PIXT *A2,A2`, A2 = 0x1fe000: the shift register is loaded from pixel
   0x3fc00, i.e. rows 510–511, which are always zero.
3. It flips the page: DPYADR and DPYSTRT both ← 0xfffc or 0xeffc (at line
   ~274.5, still in vblank), alternating each frame.
4. CONTROL ← 8, PSIZE ← 16, then `FILL L` with DADDR = 0 or 0x100000 (the
   page *not* being shown next), DPTCH = 0x2000, DYDX = 0x007f0001: 127
   one-pixel-wide rows, each a shift-register write = 1024 zero pixels. That
   clears the 254 rows of the page about to be drawn. CONTROL ← 0x2c,
   PSIZE ← 8, DPYCTL ← 0xf010 (line ~275.4).
5. The rest of the frame the game blits the new picture into that page
   (100–220 blits, ~150–290K pixels a frame in play), shown from the next
   vblank.

MAME's DMA draws instantly; the real blitter takes time, and step 1 is the
game's defence against a blit that has not finished by the next vblank.

Two things about MAME's own output that the reference renderer had to learn
(`tools/render_model.py`): `screen:pixels()` at the end of frame N returns the
picture scanned during frame N−1 (MAME keeps two bitmaps), and that bitmap is
palette indices, coloured with the palette as it is when read out (the
match-up screen blinks its text by palette).

## 8. ROMs

| file | CRC32 | size | region | layout |
|---|---|---|---|---|
| l3_nba_jam_game_rom_uj12.uj12 | b93e271c | 512 KB | maincpu | even bytes (`LOAD16_BYTE` 0) |
| l3_nba_jam_game_rom_ug12.ug12 | 407d3390 | 512 KB | maincpu | odd bytes |
| l2_nba_jam_u3_sound_rom.u3 | 3a3ea480 | 128 KB | adpcm:cpu | 0x10000 and 0x30000 |
| l1_nba_jam_u12_sound_rom.u12 (older dumps: nbau12.u12) | b94847f1 | 512 KB | adpcm:oki | 0x00000 |
| l1_nba_jam_u13_sound_rom.u13 (nbau13.u13) | b6fe24bd | 512 KB | adpcm:oki | 0x80000 |
| ug14 / uj14 / ug19 / uj19 | 04bb9f64 / b34b7af3 / a8f22fbb / 8130a8a2 | 512 KB each | video 0x000000 | `LOAD32_BYTE` bytes 0/1/2/3 |
| ug16 / uj16 / ug20 / uj20 | 8591c572 / d2e554f1 / 44fd6221 / f9cebbb6 | | video 0x200000 | |
| ug17 / uj17 / ug22 / uj22 | 6f921886 / b2e14981 / ab05ed89 / 59a95878 | | video 0x400000 | |
| ug18 / uj18 / ug23 / uj23 | 5162d3d6 / fdee0037 / 7b934c7a / 427d2eee | | video 0x600000 | |

The `video` region is declared 0xc00000 but only 0x800000 is loaded; the rest
reads zero.

## 9. What the program actually uses

From the probe (boot, attract, demo play — **not** yet a played game):
the DMA features in §7.3; protection at boot only; CMOS writes at boot
(factory restore, ~7,000 words) and rarely after; the control latch at
0x01b00000 never written after boot; the second latch at 0x01f00000 once.
Everything else in this section is to be filled from a played game and from
the TMS34010 opcode coverage of the GSP bench.

## 10. Open questions

1. **Sound status.** MAME fakes 01d0_0000. The game "checks for $82 loops";
   find in the program (Ghidra) which bit it polls and what the real board
   returns. Until then follow MAME exactly, since MAME is the oracle the
   traces are compared against.
2. **Scaling** is used in play (players and the ball, steps 0x10a–0x239);
   the largest source widths/heights are still to be measured.
3. **Page flip.** MAME's note ("page flipping seems off in NBA Jam") is not
   borne out: §7.4 is a clean double buffer in every captured frame.
