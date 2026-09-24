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

## Step 6 — The picture itself (scan-out)

The part that turns video memory into a picture on the screen. It follows the
TMS34010's rules for which memory row each screen line shows (the game
flips between its two pages by changing one register), fetches each row of
512 pixels from SDRAM in one burst, looks every pixel up in the 32,768-colour
palette and sends it to the Pocket's screen at exactly the arcade's 8 MHz
pixel rate — so the Pocket runs at the arcade's own 54.7 frames a second.

The catch: SDRAM can be busy (the blitter might be mid-burst). So the
circuit fetches each row **one line early**, into a second buffer, giving
itself a whole line's worth of time (63 microseconds) instead of the 12
microseconds before the picture starts. It keeps a counter of any line whose
fetch was late, which should always read zero.

Adapted from Smash TV's version, which already works on a Pocket. Checked the
same way as everything else: 16 frozen frames, every one of the 101,600
pixels the same colour as MAME's. First try.

## Step 7 — The CPU, proven one instruction at a time

Smash TV's TMS34010 got one addition — writing through the video chips'
shift register, for NBA Jam's page eraser — and then a hard test. MAME can
record every single thing its CPU does: every instruction, the contents of
all 32 registers before each one, and every read and write on the bus. A test
bench runs our hardware CPU on NBA Jam's own program and compares, instruction
by instruction, and it also feeds our CPU exactly the data MAME's CPU saw, so
the two stay in lockstep.

From power-on: **436,019 instructions and over a million memory accesses,
identical — and the same number of clock cycles for every instruction.** A
gameplay stretch: 315,100 more, including interrupts, identical. (Cycle
counts matter: the game's speed and its sound timing depend on the CPU taking
exactly as long as the real one.) A longer run, streaming MAME live into the
bench for over a minute of play, is still going as this is written.
**[deep dive: lockstep testing a CPU against an emulator]**

## Step 8 — The whole machine wakes up

With the CPU, the blitter, the display, the memory and the sound board wired
together, the entire arcade board runs in simulation — about 0.6 seconds of
computer time per frame. From power-on it tests its memory, finds the CMOS
blank, restores factory settings and draws the message — and **frame 99 is
identical to MAME's frame, all 101,600 pixels.** That's the first time the
real game code has drawn a picture on our hardware.

Along the way the sibling cores paid off again: Smash TV's first time on a
real Pocket had shown a blank screen because the template's video clock was
set for a different game. Its lint script now checks the clock against the
core's pixel rate — and caught the same leftover setting here before it could
cost a hardware test.

The sound board is wired too: the 6809 sound CPU, the FM chip, the sample
player and the DAC, with MAME's mixing levels — but not yet compared against
a MAME recording, so its levels are unproven.

## Step 9 — Through the Pocket's real memory, and a thousand frames in step

Up to now the simulated machine had its ROMs magically pre-loaded. On a real
Pocket the 10.6 MB file arrives one byte at a time, every eight clock ticks,
and the loader **cannot be told to wait** — if the memory is busy, a byte is
simply lost. (That exact problem cost an earlier core its first hardware
test.) So the memory module has a queue, and a test pushes the whole image
through it at the real rate — even faster than real — then reads every region
back: identical. One real bug found on the way: the sound program, which now
goes into the Pocket's separate SRAM chip, was having one word written twice
and the next skipped, because the queue moved on one tick too late.

Then the whole machine again, but fed through that real memory path: frame
99 identical to MAME. And the long run: **frame 999 — the copyright screen,
drawn by 204 blitter commands, 18 seconds after power-on — identical to
MAME's, every pixel.** The machine is keeping time with the arcade frame for
frame through boot, a button press and the attract sequence.

**The CPU marathon finished too:** 69.6 million instructions — about 21
seconds of boot, attract and gameplay — identical to MAME, including 2,077
interrupts and 1,603 uses of the page eraser. It stopped at a difference that
isn't a bug: MAME cheats slightly on long fill operations (draws instantly,
then pretends to be busy), so when an interrupt lands in that pretend-busy
time, MAME writes a different return address on the stack than real
hardware would. Both carry on identically.

**Also done:** the Pocket menu (free play, 2- or 4-player cabinet, attract
clips), button names, and **saving the game's settings and high scores** to
the SD card — borrowed from S.T.U.N. Runner, where getting the Pocket to
actually write the file took several hardware experiments.

## Step 10 — Why was the game running late? (a speed bug)

Frame 999 matched MAME perfectly, but by frame 1400 MAME was already showing
the attract-mode basketball game while ours was still on the black
"loading" screen — about half a second behind. Nothing was drawn *wrong*; it
was *late*.

Measuring how much work the CPU got done per frame explained it. The real
CPU completes 114,251 clock cycles of work every frame. Ours: **87,400 — only
76% speed.** The reason is a detail of the real chip: the TMS34010 has a tiny
built-in memory (an *instruction cache*) that holds recently used program
code, so most instructions don't have to be fetched from the slow main
memory. MAME's timing assumes that. Ours fetched every instruction from the
Pocket's SDRAM, which takes about as long as a whole instruction should. On
quiet screens the game just waits for the next frame anyway, so nothing
looked wrong — until a busy stretch.

Fix: an instruction cache of our own (4,096 words). The program ROM never
changes, so the cache can never hold a wrong value. Result: **full speed on
quiet screens (114,247 of 114,251), and 92% while the blitter is working
hardest** — the remaining gap is the CPU's data waiting behind the blitter's
bursts, a known next thing to improve. **[deep dive: caches, and why "it
looks right" can hide a speed problem]**

## Step 11 — The first real compile

The whole design, turned into an actual FPGA configuration by Intel's
Quartus tools: it **fits** — 72% of the chip's logic, 39% of its memory
blocks. But it **failed timing**: some signals couldn't get through their
logic within one tick of the 96 MHz clock. All of them were inside the CPU,
which by design only takes a step every third tick — the tools just hadn't
been told that. Smash TV's constraint file says exactly that ("these paths
have three ticks"), plus similar rules for the sound CPU, so those were
carried over. A second compile is running to check.

## Step 12 — First listen

MAME's audio and ours, recorded over the same 27 seconds of boot and
attract mode: both are silent (the attract sequence plays no sound in this
setup) — but even the silence was useful. The small DC offset left by the
sound board's DAC sitting at zero came out at −3280 in ours and −3276 in
MAME's: the DAC's scaling and polarity match. A played game is being
recorded in both now, to compare music and speech.

## Step 13 — The last 8%, and a wrong guess dropped

The remaining slowdown on busy screens looked like the CPU's data waiting
behind the blitter. So: a second cache, for the CPU's working memory, and
"posted" writes (the CPU hands over a write and carries on without waiting
for it to land). Measured: 105,260 → 105,390 cycles a frame. **Almost no
change — so that theory was wrong**, and the log says so.

The real cause was the page eraser again. Each frame it wipes the hidden
page with 127 shift-register writes, and our CPU was waiting for each
1,024-pixel copy to finish — about 9,000 cycles a frame, exactly the missing
amount. In MAME they're instantaneous. The fix is a queue: the CPU drops each
erase request in it and moves on, the memory works through the queue in the
background, and the blitter isn't allowed to start drawing on the page until
the erasing is done. Result: **114,115 of 114,251 cycles — 99.9%.**

We also made the blitter report "done" on MAME's schedule (MAME assumes 41
nanoseconds per pixel; ours is usually faster and now waits), as Smash TV
does, so the game's own timing loops see what the arcade's saw.

## Step 14 — Why some frames can never match exactly

The title screen's "TV static" still didn't match MAME, even with everything
at the right speed. Tracing the game's random-number routine explained it:
**NBA Jam seeds its random numbers from the video beam's exact position** —
which dot of which line is being drawn at that instant. That depends on
timing finer than one instruction, which MAME itself only approximates. So
any screen with something random on it (the static, every decision the
computer players make) will be correct but not identical, and is judged by
eye; the deterministic screens (boot, CMOS message, copyright, credits)
still match to the pixel. **[deep dive: where arcade games get their
randomness]**

## Step 15 — Timing, round two

With Smash TV's timing rules added, the worst path improved from −7.35 ns to
−4.0 ns. Every remaining failure was one piece of blitter arithmetic (working
out where the next row of a picture starts in the ROM) crammed into a single
clock tick. It only changes once per row, so it's now computed in advance
while the row is being drawn. Third compile running.

## Step 16 — Timing whack-a-mole, and why

Compiles three, four and five each got closer (−2.36, −2.67, −2.12 ns) and
each time every remaining failure was a *different* spot in the blitter.
That's normal for logic first written to be *correct* and only then made
*fast*: each fix exposes the next-slowest path. The blitter was doing
multiplications inside its innermost loop — one per pixel. The rewrite
works out the two possible step sizes once per picture and then just picks
one per pixel (depending on whether a fractional counter "carries"), and
splits the per-row setup across three clock ticks, each doing a single
addition. Checked after every change: all 14 frozen frames still identical
to MAME. **[deep dive: timing closure — why a chip that works in simulation
can still fail at speed]**

## Step 17 — Listening properly

Comparing two recordings of *gameplay* turned out to be comparing two
different games: the computer players make random choices, and our random
numbers differ from MAME's (step 14). So the sound board was tested on its
own, the way the methodology recommends: record every command MAME's main
CPU sends to the sound board, with its exact time, then feed exactly those
commands, at exactly those times, into our sound board, and compare.

First result: **level within about 7% of MAME's, second by second** — after
fixing one real mistake found by reading MAME's source: the speech chip's
volume was a quarter of what it should be (MAME treats each of its four
voices as full-scale; we'd divided by four). But that capture turned out to
contain no speech at all — MAME's own sound CPU never started a sample in
those 66 seconds. So a second test: while the game sits quietly, MAME is
made to send every sound command from 0 to 95 in turn, recorded, and the
same sequence replayed into ours.

Result of that sweep: all three sound chips (music, speech, and the simple
"DAC" channel) were busy, and **our loudness was within 6% of MAME's in
every one of the 66 seconds** — mostly within 3%. The waveforms themselves
drift out of step after a few seconds (two clocks that differ by a hair
eventually disagree about exactly when a note starts), so "same loudness,
second by second" is the fair test, not "same wiggle, sample by sample".
**[deep dive: how do you prove two recordings are the same sound?]**

## Step 18 — The last timing failure

Compile seven got the design to −0.36 ns: every failure was now one path,
from the little queue that holds the ROM image while it streams in from the
SD card, straight to the memory chip's address pins. Adding one more
"waiting room" register between them costs one clock per word — the loader
gives us sixteen — and the memory test (the whole 10 MB image in at the
Pocket's rate, then read back byte for byte) still passes.

**Compile eight: timing met.** Every path in the chip now finishes with at
least 0.38 ns to spare at 96 million ticks a second, at the hottest and
the coldest temperature Quartus models, and every relaxation we told the
tool about was actually applied (a rule that matches nothing is silently
ignored, so this is checked). The design fills 68% of the Pocket's FPGA.

Then the whole machine was run once more exactly as the Pocket will run it —
the 10 MB image fed in at the Pocket's speed, through the real memory
controller — and its 99th frame is still identical to MAME's, pixel for
pixel.

## Step 19 — Ready for the Pocket

Everything that can be proven without the Pocket has been:

| what | how it was checked |
|---|---|
| the picture | pixel-identical to MAME on 16 frozen moments of the game |
| the blitter | memory identical to MAME after 2,080 drawing jobs |
| the main CPU | 69.6 million instructions identical to MAME's, in order |
| the whole machine | boots to a MAME-identical screen through the real memory path |
| the sound | as loud as MAME's, second by second, across every sound command |
| the memory | a full 10 MB image in at the Pocket's speed, read back byte for byte |
| the screen | no flicker between frames (which could mark the Pocket's OLED) |
| speed | timing met on every path |

What is *not* proven is the real thing: nobody has held a Pocket running
this yet. That's next — flash it, and read the on-screen debug panel the
core draws during bring-up (docs/bringup.md says what healthy looks like).

## The explainer video

`tools/explainer/make_video.py` turns this log into a 9½-minute narrated
video (`artifacts/video/nbajam_explainer.mp4`, not committed): 20 slides
built from the project's own evidence — MAME's frames, our hardware's
frames, the loudness comparison, the timing results — with a few seconds of
our sound board playing. The [deep dive] topics are listed at the end as
candidates for follow-up videos.

## Step 20 — The first flash

The first time on a real Pocket: **it boots, and the game plays.** Two
things were wrong, and both were exactly the kind simulation can't see by
itself.

**The colours were scrambled, but the shapes were right.** And a debug
switch in the menu, "slow bursts", made the picture perfect. The memory
chip hands back data in bursts; our fast mode asks for a new word *every*
clock tick, so each word is on the wires for only about 10 nanoseconds, and
the real board's wiring evidently doesn't leave enough margin to catch it
reliably. Slowing down gives each word more time on the wires. The drawing
logic was fine all along — only the handoff between two chips wasn't. The
next build defaults to the "normal" speed that earlier cores run on real
Pockets, with the menu offering all three so one flash can compare them.
**[deep dive: why a memory that works in simulation can fail on the board]**

**There was no sound — just pops and clicks.** The cause was a self-check.
Before the game starts, the core writes two test values into the Pocket's
SRAM chip and reads them back, to prove the chip works. But the SRAM also
holds the sound board's program, which the loader had *just* written there,
and the two test values landed on top of the last two words of it: the
"start here" address the sound processor reads when it powers on. So the
sound processor started at a nonsense address and ran garbage — hence the
clicks — while the self-check proudly reported a pass. In simulation the
test never ran in the same place, so it never collided. The fix, borrowed
from the Smash TV core, which had once made a similar mistake: read what's
there first, and put it back afterwards. And the memory test bench now runs
the real self-check in the real order and then checks all 131,072 bytes of
the sound program; put the old behaviour back and the bench fails on exactly
those four bytes.

The lesson, again: a test that says "pass" only proves what it looks at.

---

*(continues as the work goes on)*
