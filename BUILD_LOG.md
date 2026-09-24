# Building NBA Jam for the Analogue Pocket — the running story

A plain-language log kept while the core is built, as raw material for an
explainer video. Each entry says what happened, why it mattered, and what
went wrong. Topics marked **[deep dive]** are ones that could carry their own,
more technical video.

---

## The big idea, in one paragraph

The Analogue Pocket doesn't *emulate* old games in software. It has an FPGA —
a chip made of millions of tiny logic blocks that can be rewired into any
circuit. A "core" is a description of the original arcade board's circuits,
so the Pocket becomes, electrically, an NBA Jam arcade board. To build one you
have to know exactly what the original board did, down to individual wires
and clock ticks. Our source of truth is MAME, the arcade emulator, which has
spent decades working out how these boards behave. Everything we build is
checked against MAME, pixel for pixel.

## What's on an NBA Jam board (1993, Midway "T-unit")

- **The main processor: a TMS34010.** An unusual chip from Texas Instruments —
  a CPU designed for graphics. It runs the game at 50 MHz and also generates
  the video timing (when each line of the picture starts, when the screen
  refreshes). **[deep dive: a CPU that addresses individual bits, not bytes]**
- **The blitter (DMA).** A dedicated drawing machine. The CPU tells it "copy
  this 60×90 picture of a player from the graphics ROM to this spot on the
  screen, shrink it by 20%, flip it left-to-right," and the blitter does it.
  Almost everything you see — court, crowd, players, ball, text — is drawn
  this way, up to about 300,000 pixels every frame.
- **Video memory** holding two full screens ("pages"): one being shown while
  the other is being drawn, swapped every frame. Each pixel is 16 bits: which
  of 32,768 colours to use.
- **The sound board** (Williams ADPCM): its own little computer (a Motorola
  6809), an FM synthesiser chip (the YM2151 — think Sega Genesis–style music),
  a sample player (OKI6295 — the announcer's "BOOMSHAKALAKA!"), and a plain
  8-bit speaker output the CPU can drive directly.
- **About 10.6 MB of ROM chips**: 8 MB of graphics, 1 MB of game program,
  1 MB of voice samples, 128 KB of sound program.

## We weren't starting from zero

Two earlier cores had already solved big pieces:

- **S.T.U.N. Runner** (Atari, 1989) also uses a TMS34010, plus the same YM2151
  and OKI sound chips.
- **Smash TV** (Midway, 1990) is NBA Jam's direct ancestor — Midway's
  "Y-unit," same CPU, same kind of blitter, and already proven on a real
  Pocket. Its CPU core runs at exactly the real chip's speed, which matters
  (see below). NBA Jam will borrow its CPU, its 6809 sound processor, and its
  approach to the display.

---

## Step 1 — Reading the board (MAME as the oracle)

We downloaded MAME's source for this board and wrote down everything: where
each chip lives in the memory map, what each button bit means, which
interrupts fire when. Then instead of just *reading* MAME, we *ran* it with
little scripts that spy on the game while it plays: counting how many things
the blitter draws per frame, logging every command the game sends to the
sound board, capturing the video chip's settings.

Things we learned that way:
- The screen is 400×254 pixels at 54.7 frames per second (not 60!).
- A busy frame asks the blitter for 326,000 pixels.
- The game has **copy protection**: a chip that answers a secret sequence of
  numbers during boot. MAME has the answer table; we'll build a tiny circuit
  that gives the same answers.
- On a fresh machine the game stops at "CMOS INVALID — FACTORY SETTINGS
  RESTORED" and waits for a button. (Every test script now presses one.)

**Gotcha: the spy tools lie quietly.** MAME's scripting has traps: if you
don't keep a reference to a "tap" (a spy on a memory address) it gets thrown
away; if your spy function returns *any* value, even "nothing", MAME treats
it as a replacement and the spy dies; on this particular driver the spies get
dropped every so often and must be re-attached every frame. Each of these
silently produced "zero events" that looked like real data. Lesson from the
methodology doc, relearned: *when a measurement is surprising, suspect the
instrument first.*

## Step 2 — The ROM image

The Pocket can't unzip a MAME romset, so we write a recipe (an ".mra" file)
and a small Python tool that assembles one 10.6 MB image from the user's own
ROM files. (We never distribute ROMs — a guard script checks every commit.)
The trick is byte order: the chips read their data in pairs of bytes in a
particular order, and the Pocket loads the file one byte at a time, so the
recipe has to interleave the ROM chips just right. Rather than trust our
reasoning, a checker compares every one of the 10.6 million bytes against
what MAME itself feeds each chip. Result: identical.

Small courtesy added: some people's romsets have two sound ROMs under older
file names; the builder now finds them by their fingerprint (CRC) instead.

## Step 3 — A "reference renderer": a model of the video, in Python

Before building any hardware, we wrote Python programs that behave exactly
like the video hardware:
1. **Scan-out model:** given the video memory, palette and the video chip's
   settings, produce the picture.
2. **Blitter model:** given the video memory before a frame and every command
   the game sent during that frame, produce the video memory after.

Then we froze 16 moments of the game in MAME (boot, attract mode, menus,
the match-up screen, real gameplay, the service menu) and checked both
models against MAME. The goal: **zero pixels different.** Getting there
turned up three genuine discoveries:

- **The invisible eraser.** Gameplay frames were off by a few hundred pixels
  — always zeros where MAME had zeros and we didn't. Ruled out, one by one:
  our spies missing commands (proved complete by cross-checking with MAME's
  debugger), the CPU writing pixels (watchpoint showed none), row copies.
  The answer: every frame, the game erases the page it's about to draw using
  a *special feature of the video memory chips* — the "shift register," which
  normally feeds pixels to the screen but can also be loaded with a blank row
  and stamped onto memory row after row. Because that happens inside the
  CPU, no spy on memory can see it. We found the code that does it
  (disassembled at address FF8262F0) and taught our spy to log it by watching
  the CPU's registers. **[deep dive: VRAM shift registers and the page clear]**
- **The emergency brake.** That same code, at the start of each vertical
  blank, checks whether the blitter is *still drawing* — and if it is, waits a
  little, then cancels it. On a real board the blitter is always done in
  time. For us that's a warning: if our blitter is ever too slow, the game
  will chop off whatever wasn't finished. Speed matters.
- **MAME's screenshot is one frame late — and repainted.** MAME keeps two
  screen buffers and hands you the previous one; and it stores colour
  *numbers*, turning them into actual colours only when you look. The
  "tonight's match-up" screen blinks its text by changing the palette, which
  is how we caught it.

Result: both models match MAME on all 16 frames. That Python code is now the
executable specification the hardware has to match.

## Step 4 — The blitter, in hardware

The real board's video memory can do one thing we can't easily copy: it's a
special dual-ported memory. The Pocket's big memory is SDRAM — cheap, huge,
fast *in bursts*, slow if you jump around. And two full 16-bit pages don't
fit in the FPGA's own small, fast memory (Smash TV could fit its one 8-bit
page; NBA Jam needs four times that). So everything lives in SDRAM, and the
design becomes a bandwidth problem. **[deep dive: why SDRAM loves bursts]**

Our blitter works a row at a time:
1. **Read** the source pixels for the row in one burst from the graphics ROM.
2. **Generate** the output pixels, one per clock tick, into a small row buffer
   on the FPGA (handling transparency, flipping, scaling, clipping, colours).
3. **Write** the finished row back in one burst, with "don't touch" flags on
   the transparent pixels.

A test bench runs the real memory controller against a simulated SDRAM chip,
replays each captured frame's commands, and compares all 524,288 pixels with
MAME. It found real bugs right away (a counter carried from the read phase
into the write phase, so every row landed 87 pixels late) — and one bug in
*our own documentation*: we had written "the game never uses skip mode" (a
compression feature of the blitter), because our first survey never reached
the match-up screen. The portraits there use it. Implemented, corrected in
the docs, and now all 14 frames match MAME exactly.

**Speed.** The first working version kept the memory busy for up to 69% of a
frame just for the blitter — before the screen, the CPU and the page eraser
get a turn. Too slow; the "emergency brake" above would start chopping
graphics. Two changes to the memory controller:
- burst one word per clock instead of one every two (the memory chip allows
  it; the controller was being cautious);
- don't pause a burst every 32 words unless someone is actually waiting.

Worst frame now: 47% of a frame (2.85 clock ticks per pixel, faster than the
real board's ~3.9). Gameplay: 26–36%. Still pixel-exact. These controller
changes are switched off for the other cores that share the file, because
they're not yet proven on real hardware.

## Step 5 — Choosing the CPU

Two TMS34010 cores exist from earlier projects. STUN Runner's supports
everything but doesn't keep the real chip's timing. Smash TV's counts the
real chip's cycles, so the game runs at the right speed, and is proven on a
Pocket. We measured which instructions NBA Jam uses (6.6 million
instructions traced in MAME): all the graphics instructions it uses exist in
Smash TV's core except one variation — writing through the shift register,
the page eraser from above. So: Smash TV's CPU, plus that one addition.

---

*(continues as the work goes on)*
