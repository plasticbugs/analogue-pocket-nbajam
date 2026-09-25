# NBA Jam for Analogue Pocket — 0.2.1

**0.2.1 fixes the ROM recipes; the core itself is unchanged from 0.2.0**
(same bitstream, md5 `97a294176f0ab618921b9efbc99ebab4`).

- **The standard `mra` tool now builds correct images.** The `.mra` files
  wrote their interleave `map` digits in the reverse of the MRA convention, so
  `mra` produced scrambled images (with only an md5 warning). Both
  `mra -z <romdir> nbajam.mra` and `mra -z <romdir> nbajamte.mra` now give
  exactly the images below, and so does `mra_build.py`.
- **Merged romsets work.** A merged `nbajamte.zip` also holds the clone
  `nbajamte4`'s same-named `ug12` in a subfolder; `mra_build.py` picked the
  wrong one. It now chooses by CRC.
- Romset notes: Tournament Edition is MAME's `nbajamte` (rev 4.0 3/23/94).
  Older sets that name NBA Jam's two speech ROMs `nbau12.u12` / `nbau13.u13`
  (before MAME 0.253) work with both tools: `mra` and `mra_build.py` find a
  file by its CRC as well as its name.

---

## 0.2.0

Midway's T-unit arcade board as an openFPGA core, now running **both NBA Jam
(1993, rev 3.01)** and **NBA Jam Tournament Edition (1994, rev 4.0 3/23/94)**.
Tested on a Pocket: picture, sound and smooth play in both.

## New in 0.2.0

- **Tournament Edition.** Pick the game from the list when the core starts;
  the core recognises which one it was given from the ROM itself. Each game
  keeps its own settings and high scores.
- **Smoother play.** Busy scenes (a basket in view) no longer drop frames:
  the video memory now writes at full rate.
- **Controls laid out like the arcade panel** (from 0.1.1): Y turbo, X shoot,
  A pass; B is a second pass and R a second turbo.
- **Settings and high scores kept**: service-mode settings, audits and high
  scores are saved to the SD card per game
  (`Saves/nbajam/plasticbugs.nbajam/nbajam.sav`, `nbajamte.sav`) and loaded
  back when the core starts.
- The platform image, correct game details (Midway, 1993), and the
  diagnostic items gone from the menu.

## Installing

1. Unzip onto the root of the SD card (`Cores/`, `Platforms/`, `Assets/`).
   Coming from 0.1.x, replace everything; the game list is new.
2. Build the ROM images from your own MAME romsets — no ROM data is
   included, and none ever will be:

       python3 mra_build.py nbajam.mra nbajam.zip        # md5 b6a0b85732103ba8ec4fa6a65ddd2c32
       python3 mra_build.py nbajamte.mra nbajamte.zip    # md5 1ae1931e7073e9131c9c9336bc6b0fdc

3. Put them in `Assets/nbajam/common/` (`nbajam.rom`, `nbajamte.rom`).

On the very first start each game says "CMOS INVALID -- FACTORY SETTINGS
RESTORED": press any button. That is the arcade's own behaviour with a blank
settings memory.

## Controls

Laid out like the arcade panel (Turbo, Shoot, Pass from left to right):
Y turbo, X shoot / block, A pass / steal; B is a second pass, R a second
turbo; Select coin, Start start.

## Menu

Free Play, Cabinet (2 or 4 player), Attract Video Clips (NBA Jam only),
and Service Switch + Reset Core for the game's own test menu.

## Known limits

- When the game clears a whole screen with its CPU (scene changes such as the
  tip-off) this core takes about three frames where the arcade takes one, so
  those moments hitch briefly.
- Players 3 and 4 are not wired.
- A game never replays exactly like MAME's: NBA Jam takes its random numbers
  from the video beam's position, as the arcade did.

## How it was checked

Against MAME 0.288, for each game:
- the ROM image byte-identical to what MAME feeds each chip;
- the picture pixel-identical on frozen moments of the game (16 NBA Jam,
  14 Tournament Edition);
- the CPU identical, instruction by instruction, for ~69 million
  instructions from power-on;
- Tournament Edition's copy protection: all 768 accesses of its boot
  identical to MAME's;
- sound as loud as MAME's, second by second, across every sound command;
- timing met at 96 MHz.

On hardware: a fast memory mode that garbled colours (reads), a self-test that
overwrote the sound CPU's start address, and frame drops in Tournament
Edition's busiest scenes, each found on a Pocket and fixed. The full story is
in `BUILD_LOG.md`.

## Credits

MAME's midtunit driver (Alex Pasadyn, Zsolt Vasvari, Ernesto Corvi, Aaron
Giles); jt51 and jt6295 by Jose Tejada; the MC6809 core by Greg Miller; the
Pocket platform and build image by Marcus Andrade (OpenGateware); the Smash TV,
S.T.U.N. Runner and Pleiads Pocket cores it grew from. See CREDITS.md.
