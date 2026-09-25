# MAME sources this core was written against

Fetch the driver and every device it uses **verbatim**, record the MAME version
and commit here, and never edit them: they are the citation for
`docs/hardware.md`.

**Version: MAME 0.288.** `src/mame/midway/midtunit.cpp` here is byte-identical
to the `mame0288` tag of mamedev/mame (checked 2026-09-25 with the GitHub API).

Romset history that matters to users (checked at the tags):
- `nbajamte` has been Tournament Edition **rev 4.0 3/23/94** (program ROMs
  `ug12` 7ad49229, `uj12` d7c21bc4) from at least MAME 0.130 to 0.289, and
  every file name `nbajamte.mra` uses is already present at 0.200.
- `nbajam`'s two OKI ROMs were renamed in **0.253**: `nbau12.u12` /
  `nbau13.u13` became `l1_nba_jam_u12_sound_rom.u12` / `..._u13...`. Both the
  standard `mra` tool (mra-tools-c tries a file's CRC before its name) and
  `mra_build.py` find the old names by CRC, so older sets work.
