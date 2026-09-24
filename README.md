# NBA Jam — Analogue Pocket core (openFPGA)

**NBA Jam** (Midway, 1993, rev 3.01) on the Analogue Pocket: Midway's
T-unit board in gateware — the TMS34010 graphics CPU at 50 MHz, the DMA
blitter, two 512×512 16-bit frame buffers, a 32K-colour palette, and the
Williams ADPCM sound board (MC6809E, YM2151, OKI MSM6295, DAC). Nothing is
emulated in software.

> **ROMs are not included and never will be.** You supply your own MAME
> `nbajam` romset; the core reads one image built from it.

| board part | implementation | verified by |
|---|---|---|
| TMS34010 @ 50 MHz | `rtl/tms34010.sv`, Smash TV's, cycle-paced, plus shift-register writes | `sim/run_cpu.sh`: 69.6 M instructions from reset identical to MAME's trace, registers, bus and cycle counts |
| DMA blitter | `rtl/tunit_dma.sv` | `sim/run_blit.sh`: VRAM identical to MAME on 14 frozen frames (2,080 blits) through the real SDRAM controller |
| scan-out, palette | `rtl/tunit_video.sv`, from Smash TV's | `sim/run_video.sh`: every pixel identical to MAME on 16 frozen frames |
| main board glue, protection, CMOS | `rtl/tunit_main.sv` | the machine benches: frames 99 and 999 from power-on identical to MAME |
| MC6809E @ 2 MHz | `modules/cpu-mc6809` (Greg Miller) | the sound board as a whole, below |
| YM2151 | `modules/sound-jt51` (Jose Tejada) | `sim/run_sound.sh`: MAME's sound commands replayed at MAME's times; loudness within 0.96–1.12× of MAME every second over 66 s with all three chips playing |
| OKI MSM6295 | `modules/sound-jt6295` (Jose Tejada) | as above; level scaled from MAME's source (×16) |
| ROM, VRAM, work RAM | Pocket SDRAM (`target/pocket/nbajam_mem.sv`) | `sim/run_mem.sh` at the loader's rate; `sim/run_system.sh` |
| 6809 program | Pocket SRAM | `sim/run_mem.sh` |

## Status

**0.1.0 runs on a Pocket: picture and sound reported perfect** (2026-09-24,
bitstream md5 `05629f94f775fc5f4a3e03e8254fe5d3`, SDRAM bursts on Normal).

Proven in simulation, against MAME 0.288:
* the reference models (`tools/render_model.py`, `tools/dma_model.py`) are
  pixel-exact against MAME on 16 captured frames;
* the video RTL matches them (above);
* the CPU matches MAME instruction for instruction for 69.6 M instructions;
* the whole machine, through the real Pocket memory glue with the image
  downloaded at the loader's rate, boots to a MAME-identical frame, and on the
  faster bench keeps MAME's timeline to frame 999 (the copyright screen);
* the sound board, fed MAME's own commands at MAME's times, is as loud as
  MAME's to within 6% in every second of a 66-second sweep of every command;
* timing closes at 96 MHz (+0.05 ns worst setup in the released build, every
  corner, every SDC constraint applied), about 68% of the FPGA's logic;
* scaled skip-mode blits, the one case not drawn exactly, never occur: 0 in
  4.8 M blits over five minutes each of attract and play in MAME.

Not yet proven: the per-chip balance of the mix (the waveforms drift apart,
so only the total loudness was compared); a played game matching MAME (the
game's random numbers come from the beam position, so it cannot match
exactly); the CMOS save on hardware; the Fast SDRAM burst setting (it
scrambles the palette on hardware; Normal is the default).

Not implemented: scaled skip-mode blits (never seen; counted on the panel);
players 3 and 4.

## Building the ROM image

```sh
python3 mra_build.py nbajam.mra nbajam.zip
```

The builder needs only Python 3. It reads the MAME zip (or a directory of loose
files), checks every ROM's CRC32, and verifies the finished image against a
known md5. Copy the result to `Assets/nbajam/common/nbajam.rom` on the SD card.

## Building the core

`./build-local.sh` compiles with Quartus 18.1 in Docker and leaves the SD-card
package in `release/pocket/`. `./build-local.sh map` runs analysis and synthesis
only — a couple of minutes, and it catches what Verilator cannot.

## Checking it

```sh
sim/lint.sh                    # every module on its own
sim/run_mem.sh                 # the Pocket's memory path, at the loader's real rate
tools/capture_states.sh        # frozen states from MAME (then:)
python3 tools/check_states.py .build/nbajam.rom artifacts/states   # models vs MAME
sim/run_blit.sh .build/nbajam.rom                                  # blitter RTL vs MAME
sim/run_video.sh                                                   # scan-out RTL vs MAME
tools/cpu_trace.sh; sim/run_cpu.sh     # the CPU vs MAME's traces (or -live <seconds>)
sim/run_machine.sh -frames N -inputs tools/inputs/play1.txt -snap ...   # the machine
sim/run_system.sh  -frames N ...       # the machine through the real memory glue
```

## Credits

`CREDITS.md` is the full list, and a core should extend it with its own. The
short of it: **Marcus Andrade**
([@boogermann](https://github.com/boogermann),
[OpenGateware](https://github.com/opengateware) /
[Raetro](https://github.com/raetro)) wrote everything between the arcade
hardware and the Pocket — `platform/pocket/` is OpenGateware's
`gateman-pocket` platform, 41 of its 63 files are his, `projects/` came from
his Gateman CLI, `target/pocket/core_top.sv` starts from his template, and
every build here runs in his `raetro/quartus:pocket` Docker image.

Then: MAME, for the driver and devices this was written against (`ref/mame/`);
the vendored cores and their authors (`modules/VENDOR.md`); Analogue, for the
APF; and anyone whose board photographs, schematics or measurements are in
`docs/hardware.md`.
