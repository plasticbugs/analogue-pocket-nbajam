# NBA Jam for Analogue Pocket — 0.1.0

The first release: Midway's 1993 NBA Jam arcade board (the "T-unit") as an
openFPGA core, tested on a Pocket with picture and sound correct.

## Installing

1. Unzip onto the root of the SD card (`Cores/`, `Platforms/`, `Assets/`).
2. Build the ROM image from your own MAME `nbajam` romset — no ROM data is
   included, and none ever will be:

       python3 mra_build.py nbajam.mra nbajam.zip

   The result must have md5 `b6a0b85732103ba8ec4fa6a65ddd2c32`.
3. Put it at `Assets/nbajam/common/nbajam.rom`.

On the very first start the game says "CMOS INVALID -- FACTORY SETTINGS
RESTORED": press any button. That is the arcade's own behaviour with a blank
settings memory.

## Controls

A shoot, B pass, X / Y / R turbo, Select coin, Start start.

## Menu

- **Free Play**, **Cabinet** (2 or 4 player), **Attract Video Clips**.
- **Service Switch** + Reset Core: the game's own test menu.

## Known limits

- Players 3 and 4 are not wired.
- A game can never replay exactly like MAME's: NBA Jam takes its random
  numbers from the video beam's position, as the arcade did.
- Saving of settings and high scores to the SD card is in, not yet confirmed
  on hardware.

## How it was checked

Against MAME 0.288:
- picture pixel-identical on 16 frozen moments;
- the blitter's video memory identical after 2,080 drawing jobs;
- the CPU identical, instruction by instruction, for 69.6 million instructions;
- sound as loud as MAME's, second by second, across every sound command;
- timing met at 96 MHz.

The first hardware build found two faults simulation could not: a fast memory
mode unreliable on the board, and a power-on self-test that overwrote the
sound CPU's reset vector. Both are fixed here. The full story is in
`BUILD_LOG.md`.

## Credits

MAME's midtunit driver (Alex Pasadyn, Zsolt Vasvari, Ernesto Corvi, Aaron
Giles); jt51 and jt6295 by Jose Tejada; the MC6809 core by Greg Miller; the
Pocket platform and build image by Marcus Andrade (OpenGateware); the Smash TV
and S.T.U.N. Runner Pocket cores it grew from. See CREDITS.md.
