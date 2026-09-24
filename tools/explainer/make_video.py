#!/usr/bin/env python3
"""The explainer video: how this core was built, in mostly plain language.

Slides are drawn here from the project's own artifacts (MAME's frames, the
RTL's frames, the sound recordings, the compile results), narrated with
macOS `say`, and joined with ffmpeg.  The story follows BUILD_LOG.md.

    python3 -m venv /tmp/v && /tmp/v/bin/pip install pillow numpy
    /tmp/v/bin/python tools/explainer/make_video.py      # -> artifacts/video/

Needs the (untracked) artifacts the benches wrote: artifacts/states/mame_*.png,
artifacts/machine/frame_*.rgb, artifacts/audio/mame_sweep.wav and
artifacts/audio/sweep/rtl_mix.wav.  The video is not committed.
"""
import os, subprocess, sys, wave, shutil
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
OUT = os.path.join(ROOT, 'artifacts', 'video')
WORK = os.path.join(OUT, 'build')
W, H = 1920, 1080
VOICE, RATE = 'Samantha', 172

BG0, BG1 = (14, 17, 22), (22, 27, 36)
FG, DIM = (236, 238, 242), (150, 158, 170)
ORANGE, TEAL = (240, 118, 40), (60, 200, 200)
RED, GREEN = (230, 70, 70), (80, 200, 110)

AV = '/System/Library/Fonts/Avenir Next.ttc'
def font(size, face='Regular'):
    idx = {'Bold': 0, 'Demi': 2, 'Medium': 5, 'Regular': 7, 'Heavy': 8}[face]
    return ImageFont.truetype(AV, size, index=idx)
MONO = lambda s: ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', s)

def art(p): return os.path.join(ROOT, 'artifacts', p)


# ------------------------------------------------------------ drawing
def canvas():
    im = Image.new('RGB', (W, H))
    g = np.linspace(0, 1, H)[:, None, None]
    a = np.array(BG0)[None, None] * (1 - g) + np.array(BG1)[None, None] * g
    im = Image.fromarray(np.broadcast_to(a, (H, W, 3)).astype(np.uint8))
    d = ImageDraw.Draw(im)
    d.rectangle([0, H - 10, W, H], fill=ORANGE)
    return im, d

def wrap(d, text, f, width):
    out = []
    for para in text.split('\n'):
        line = ''
        for w in para.split(' '):
            t = (line + ' ' + w).strip()
            if d.textlength(t, font=f) <= width: line = t
            else: out.append(line); line = w
        out.append(line)
    return out

def para(d, xy, text, size=40, width=800, fill=FG, face='Regular', gap=1.35):
    x, y = xy; f = font(size, face)
    for ln in wrap(d, text, f, width):
        d.text((x, y), ln, font=f, fill=fill); y += int(size * gap)
    return y

def header(d, title, kicker=None):
    y = 70
    if kicker:
        d.text((110, y), kicker.upper(), font=font(30, 'Demi'), fill=ORANGE); y += 50
    d.text((110, y), title, font=font(66, 'Bold'), fill=FG)
    return y + 110

def frame_img(path_or_img, scale):
    im = path_or_img if isinstance(path_or_img, Image.Image) else Image.open(path_or_img).convert('RGB')
    return im.resize((im.width * scale // 2, im.height * scale // 2), Image.NEAREST) if scale % 2 else \
        im.resize((im.width * scale // 2, im.height * scale // 2), Image.NEAREST)

def paste(im, sub, xy, border=TEAL, label=None):
    d = ImageDraw.Draw(im)
    x, y = xy
    d.rectangle([x - 4, y - 4, x + sub.width + 3, y + sub.height + 3], outline=border, width=4)
    im.paste(sub, (x, y))
    if label:
        d.text((x, y + sub.height + 14), label, font=font(30, 'Demi'), fill=DIM)

def rtl_frame(n):
    return Image.frombytes('RGB', (400, 254), open(art(f'machine/frame_{n:05d}.rgb'), 'rb').read())

def box(d, rect, title, sub=None, col=TEAL, tsize=34):
    x0, y0, x1, y1 = rect
    d.rounded_rectangle(rect, radius=18, outline=col, width=4, fill=(24, 30, 40))
    f = font(tsize, 'Demi')
    tw = d.textlength(title, font=f)
    yy = y0 + (y1 - y0) // 2 - (tsize if sub else tsize // 2 + 4)
    d.text(((x0 + x1 - tw) / 2, yy), title, font=f, fill=FG)
    if sub:
        fs = font(26)
        for i, ln in enumerate(sub.split('\n')):
            sw = d.textlength(ln, font=fs)
            d.text(((x0 + x1 - sw) / 2, yy + tsize + 14 + i * 34), ln, font=fs, fill=DIM)

def arrow(d, a, b, col=DIM, w=5):
    d.line([a, b], fill=col, width=w)
    ax, ay = a; bx, by = b
    v = np.array([bx - ax, by - ay], float); v /= np.linalg.norm(v)
    n = np.array([-v[1], v[0]])
    p = np.array(b); q1 = p - 22 * v + 11 * n; q2 = p - 22 * v - 11 * n
    d.polygon([tuple(p), tuple(q1), tuple(q2)], fill=col)

def bignum(d, xy, num, label, col=ORANGE):
    d.text(xy, num, font=font(120, 'Heavy'), fill=col)
    d.text((xy[0], xy[1] + 150), label, font=font(36), fill=FG)


# ------------------------------------------------------------ slides
S = []
def slide(narration, audio_after=None):
    def deco(fn):
        S.append((fn, narration, audio_after)); return fn
    return deco

@slide("This is the story of how an N B A Jam arcade core was built for the "
       "Analogue Pocket. Not an emulator: a re-creation of the original 1993 "
       "arcade board's circuits. Here's what that means, how it was done, and "
       "how we know it's right.")
def s_title():
    im, d = canvas()
    im.paste(frame_img(art('states/mame_00400.png'), 4), (W - 800 - 110, 250))
    d.text((110, 300), 'NBA Jam', font=font(120, 'Heavy'), fill=ORANGE)
    d.text((110, 450), 'on the Analogue Pocket', font=font(64, 'Bold'), fill=FG)
    para(d, (110, 580), 'How the FPGA core was built, and how we know it is right',
         size=38, width=820, fill=DIM)
    return im

@slide("The Pocket doesn't run old games in software. Inside it is an F P G A: "
       "a chip made of millions of tiny logic blocks that can be rewired into "
       "any circuit. An emulator is a program pretending to be the hardware. "
       "A core rewires the chip so that it becomes the hardware, electrically, "
       "tick for tick. To do that, you have to know exactly what the original "
       "board did, down to single wires and clock ticks.")
def s_fpga():
    im, d = canvas()
    y = header(d, 'Not an emulator', 'The big idea')
    box(d, (110, y + 20, 900, y + 380), 'Emulator',
        'a program on a normal processor\npretends to be each chip,\none step at a time', col=DIM, tsize=48)
    box(d, (1020, y + 20, 1810, y + 380), 'FPGA core',
        'the chip is rewired into\nthe arcade board\'s circuits,\nall running at once', col=ORANGE, tsize=48)
    para(d, (110, y + 450), 'The Pocket becomes, electrically, an NBA Jam board.',
         size=44, width=1700, face='Demi')
    return im

@slide("Our source of truth is Mame, the arcade emulator, which people have spent "
       "decades refining. Mame is the answer key. Every part we build is checked "
       "against it: the same picture, pixel for pixel; the same processor "
       "instructions, one by one; the same sound. When a result surprised us, "
       "the first suspect was always our own measuring tools.")
def s_mame():
    im, d = canvas()
    y = header(d, 'MAME is the answer key', 'The method')
    rows = [('Picture', 'every pixel the same colour as MAME\'s'),
            ('Processor', 'every instruction, register and memory access the same'),
            ('Sound', 'the same commands in, the same loudness out'),
            ('Rule', 'when a result surprises you, suspect the instrument first')]
    for i, (a, b) in enumerate(rows):
        d.text((110, y + 30 + i * 120), a, font=font(46, 'Bold'), fill=ORANGE if i < 3 else TEAL)
        d.text((480, y + 36 + i * 120), b, font=font(42), fill=FG)
    return im

@slide("Here's what's on an N B A Jam board, Midway's T unit from 1993. The main "
       "processor is a T M S thirty-four-oh-ten, an unusual Texas Instruments "
       "chip designed for graphics. Beside it, the blitter: a drawing machine. "
       "The processor says, copy this picture of a player from the graphics ROM "
       "to here, shrink it, flip it, and the blitter does it, up to three hundred "
       "thousand pixels a frame. Video memory holds two screens, one shown while "
       "the other is drawn. And the sound board is a whole second computer: a "
       "sixty-eight-oh-nine processor, an F M music chip, a sample player for the "
       "announcer's boom shakalaka, and a simple speaker output. About ten and a "
       "half megabytes of ROM chips hold it all.")
def s_board():
    im, d = canvas()
    y = header(d, 'What is on the board', 'Midway T-unit, 1993')
    box(d, (110, y, 590, y + 190), 'TMS34010', 'graphics CPU, 50 MHz', ORANGE)
    box(d, (720, y, 1200, y + 190), 'Blitter', 'draws every sprite', ORANGE)
    box(d, (1330, y, 1810, y + 190), 'Video memory', 'two screens, 32,768 colours', ORANGE)
    box(d, (110, y + 330, 590, y + 520), 'ROMs', '8 MB graphics · 1 MB program\n1 MB voice · 128 KB sound', DIM)
    box(d, (720, y + 330, 1810, y + 520), 'Sound board',
        '6809 CPU · YM2151 FM music · OKI6295 speech · DAC', TEAL)
    arrow(d, (590, y + 95), (720, y + 95)); arrow(d, (1200, y + 95), (1330, y + 95))
    arrow(d, (350, y + 190), (350, y + 330)); arrow(d, (960, y + 330), (960, y + 190))
    arrow(d, (590, y + 425), (720, y + 425))
    return im

@slide("We weren't starting from zero. Two earlier Pocket cores had solved big "
       "pieces. S T U N Runner, from Atari, uses the same graphics processor and "
       "the same sound chips. And Smash T V is N B A Jam's direct ancestor: "
       "Midway's previous board, the same processor, the same kind of blitter, "
       "already proven on a real Pocket. Its processor runs at exactly the real "
       "chip's speed, which turned out to matter a lot.")
def s_siblings():
    im, d = canvas()
    y = header(d, 'Standing on two earlier cores', 'Not from zero')
    box(d, (110, y + 20, 900, y + 340), 'S.T.U.N. Runner', 'Atari, 1989\nsame CPU family\nsame YM2151 + OKI sound chips', DIM, 52)
    box(d, (1020, y + 20, 1810, y + 340), 'Smash TV', 'Midway Y-unit, 1990\nNBA Jam\'s ancestor\nCPU proven on a Pocket', ORANGE, 52)
    para(d, (110, y + 410), 'Borrowed: the cycle-exact CPU, the sound CPU, the display approach, the memory controller.',
         size=38, width=1700, fill=DIM)
    return im

@slide("Step one was reading the board. We fetched Mame's source for it and wrote "
       "everything down. Then we ran Mame with little spy scripts to measure "
       "the game as it plays. The screen is four hundred by two fifty four pixels, "
       "at fifty four point seven frames a second, not sixty. A busy frame asks "
       "the blitter for three hundred and twenty six thousand pixels. And the game "
       "has copy protection: a chip that must answer a secret sequence during boot. "
       "The spies had traps, too. Mame's scripting silently drops them, and more "
       "than once zero events looked like real data.")
def s_reading():
    im, d = canvas()
    y = header(d, 'Reading the board', 'Step 1')
    bignum(d, (110, y), '400×254', 'pixels, at 54.7 frames a second')
    bignum(d, (1000, y), '326,000', 'pixels drawn in a busy frame', TEAL)
    para(d, (110, y + 300), 'Copy protection: a chip that answers a secret sequence at boot — '
         'rebuilt as a tiny table-driven circuit.', size=38, width=1700)
    para(d, (110, y + 430), 'Trap: MAME\'s scripting silently drops spies, so "zero events" looked like data.',
         size=34, width=1700, fill=DIM)
    return im

@slide("The Pocket can't open a Mame zip file, so a recipe and a small tool build "
       "one ten point six megabyte image from the player's own ROMs. No ROMs are "
       "ever shipped: a guard script checks every commit. The tricky part is byte "
       "order. Rather than trust our reasoning, a checker compared every one of "
       "those ten million bytes with what Mame itself feeds each chip. Identical.")
def s_rom():
    im, d = canvas()
    y = header(d, 'The ROM image', 'Step 2')
    bignum(d, (110, y), '10,616,832', 'bytes checked against what MAME feeds each chip')
    d.text((110, y + 250), 'identical', font=font(80, 'Heavy'), fill=GREEN)
    para(d, (110, y + 400), 'Built from your own ROM files. No ROM data is ever distributed.',
         size=38, width=1700, fill=DIM)
    return im

@slide("Before building any hardware, we wrote Python programs that behave exactly "
       "like the video hardware: one that turns video memory into a picture, and "
       "one that plays the blitter's drawing commands. Then we froze sixteen "
       "moments of the game in Mame: boot, attract mode, menus, the match up "
       "screen, gameplay, the service menu. The goal was zero pixels different. "
       "That Python code became the specification the hardware has to meet.")
def s_model():
    im, d = canvas()
    y = header(d, 'A model of the video, in Python', 'Step 3')
    ns = [100, 400, 1000, 1250, 1400, 1700, 1900, 2300, 2500, 3000, 3500, 5200]
    for i, n in enumerate(ns):
        sub = Image.open(art(f'states/mame_{n:05d}.png')).convert('RGB').resize((400, 254))
        x = 110 + (i % 4) * 430; yy = y - 10 + (i // 4) * 272
        im.paste(sub, (x, yy))
    d.text((1840 - 10 - d.textlength('0 pixels different', font=font(40, 'Heavy')), y - 90),
           '0 pixels different', font=font(40, 'Heavy'), fill=GREEN)
    return im

@slide("Getting to zero turned up a mystery. Gameplay frames were off by a few "
       "hundred pixels. Zeros, where Mame had zeros and we didn't. The answer was "
       "an invisible eraser. Every frame, the game wipes the page it's about to "
       "draw using a special feature of the video memory chips: a shift register "
       "that normally feeds pixels to the screen, but can be loaded with a blank "
       "row and stamped onto memory, row after row. It happens inside the "
       "processor, so no spy on memory could see it. We found the code that does "
       "it, and taught our spy to watch the processor instead.")
def s_eraser():
    im, d = canvas()
    y = header(d, 'The invisible eraser', 'A mystery')
    x0, y0 = 110, y + 10
    for r in range(12):
        col = (60, 66, 78) if r < 7 else (150, 60, 40)
        d.rectangle([x0, y0 + r * 44, x0 + 820, y0 + r * 44 + 34], fill=col)
    d.rectangle([x0 + 900, y0 + 7 * 44 - 6, x0 + 1200, y0 + 7 * 44 + 40], outline=ORANGE, width=4)
    d.text((x0 + 920, y0 + 7 * 44 - 2), 'blank row', font=font(32, 'Demi'), fill=ORANGE)
    arrow(d, (x0 + 900, y0 + 7 * 44 + 17), (x0 + 830, y0 + 7 * 44 + 17), ORANGE)
    para(d, (x0 + 900, y0), 'The video chips\' shift register, loaded with zeros, stamped onto memory one '
         'row at a time: 127 times a frame.', size=34, width=780)
    para(d, (x0 + 900, y0 + 420), 'Inside the CPU — invisible to every memory spy.', size=34,
         width=780, fill=DIM)
    return im

@slide("Now the hardware. The real board's video memory is special dual ported "
       "memory. The Pocket's big memory is S D RAM: huge and cheap, fast in "
       "bursts, slow if you jump around. So our blitter works a row at a time: "
       "read the source pixels in one burst, build the output row on the chip, "
       "then write it back in one burst. The test bench compared all half a "
       "million pixels of video memory with Mame after each frozen frame, and "
       "found real bugs straight away, including one in our own notes: we had "
       "written that the game never uses the blitter's skip mode. The player "
       "portraits do. Now fourteen frames match exactly.")
def s_blitter():
    im, d = canvas()
    y = header(d, 'The blitter, in hardware', 'Step 4')
    xs = [110, 690, 1270]
    for x, (t, s) in zip(xs, [('Read', 'one burst of source\npixels from ROM'),
                              ('Generate', 'one pixel per tick:\nflip, scale, clip, colour'),
                              ('Write', 'one burst back to\nvideo memory')]):
        box(d, (x, y + 10, x + 540, y + 250), t, s, ORANGE, 52)
    arrow(d, (650, y + 130), (690, y + 130)); arrow(d, (1230, y + 130), (1270, y + 130))
    bignum(d, (110, y + 330), '2,080', 'drawing jobs, video memory identical to MAME', GREEN)
    para(d, (1000, y + 360), 'Busiest frame: memory busy 69% down to 47% after teaching the '
         'controller to burst one word per tick.', size=34, width=820, fill=DIM)
    return im

@slide("The processor came from Smash T V, with one addition: writing through that "
       "shift register, for the eraser. Then a hard test. Mame can record "
       "everything its processor does: every instruction, all thirty two registers, "
       "every read and write. A test bench runs our hardware processor on N B A "
       "Jam's own program, in lockstep. Sixty nine point six million instructions, "
       "about twenty one seconds of boot, attract mode and gameplay: identical, "
       "down to the number of clock cycles each one took.")
def s_cpu():
    im, d = canvas()
    y = header(d, 'The processor, in lockstep', 'Steps 5 and 7')
    bignum(d, (110, y), '69,587,010', 'instructions identical to MAME\'s, in order')
    para(d, (110, y + 290), 'Same registers, same memory accesses, same clock cycles for every one. '
         'Including 2,077 interrupts and 1,603 uses of the eraser.', size=38, width=1700)
    return im

@slide("With the processor, the blitter, the display, the memory and the sound "
       "board wired together, the whole arcade board runs in simulation. From "
       "power on it tests its memory, restores factory settings, and draws. "
       "Frame ninety nine: identical to Mame's. Frame nine hundred ninety nine, "
       "the copyright screen, eighteen seconds after power on: identical, every "
       "pixel. Ours on the left, Mame's on the right.")
def s_machine():
    im, d = canvas()
    y = header(d, 'The whole machine wakes up', 'Steps 8 and 9')
    c = Image.open(art('machine/cmp_00999.png')).convert('RGB')
    l, r = c.crop((0, 0, 400, 254)), c.crop((400, 0, 800, 254))
    paste(im, l.resize((800, 508), Image.NEAREST), (110, y + 10), ORANGE, 'our hardware (simulated), frame 999')
    paste(im, r.resize((800, 508), Image.NEAREST), (1010, y + 10), DIM, 'MAME')
    d.text((110, y + 600), '0 of 101,600 pixels different', font=font(44, 'Heavy'), fill=GREEN)
    return im

@slide("Then a puzzle. Frame nine ninety nine was perfect, but by frame fourteen "
       "hundred Mame was showing the attract mode game while ours was still on "
       "a black screen. Nothing was wrong, just late. Our processor was running "
       "at seventy six percent speed, because the real chip has a tiny built in "
       "cache for recent program code, and ours fetched everything from slow "
       "memory. A cache of our own got it to ninety two percent. Next guess: "
       "a second cache for data. Measured: almost no change, so that theory was "
       "dropped, out loud. The real cause was the eraser again: the processor "
       "waited for every row. A queue let it carry on. Ninety nine point nine "
       "percent.")
def s_speed():
    im, d = canvas()
    y = header(d, 'Why was the game running late?', 'Steps 10 and 13')
    bars = [('first try', 76.5, RED), ('+ instruction cache', 92.1, ORANGE),
            ('+ data cache (wrong guess)', 92.2, DIM), ('+ eraser queue', 99.9, GREEN)]
    for i, (lab, v, col) in enumerate(bars):
        yy = y + 10 + i * 140
        d.text((110, yy + 18), lab, font=font(36, 'Demi'), fill=FG)
        d.rectangle([700, yy, 700 + int(v * 10.5), yy + 90], fill=col)
        d.text((720 + int(v * 10.5), yy + 18), f'{v}%', font=font(40, 'Bold'), fill=col)
    para(d, (110, y + 590), 'CPU work done per frame, as a share of the real chip\'s 114,251 cycles',
         size=32, width=1700, fill=DIM)
    return im

@slide("Some screens can never match exactly, and now we know why. N B A Jam gets "
       "its random numbers from the exact position of the video beam at that "
       "instant: which dot of which line is being drawn. That depends on timing "
       "finer than one instruction, which Mame itself only approximates. So the "
       "title screen's T V static, and every decision the computer players make, "
       "is correct but not identical. Deterministic screens still match to the "
       "pixel.")
def s_random():
    im, d = canvas()
    y = header(d, 'Randomness from the beam', 'Step 14')
    paste(im, frame_img(art('states/mame_00400.png'), 4), (110, y + 10), DIM, 'the static on the title screen')
    para(d, (1010, y + 20), 'The random numbers are seeded from which dot of which line the '
         'screen is drawing at that instant.', size=40, width=800)
    para(d, (1010, y + 330), 'Random screens: judged by eye.\nEverything else: pixel-exact.',
         size=40, width=800, fill=TEAL, face='Demi')
    return im

def sweep_rms():
    def rd(p):
        w = wave.open(p); a = np.frombuffer(w.readframes(w.getnframes()), '<i2').astype(float)
        return a, w.getframerate()
    m, fs = rd(art('audio/mame_sweep.wav')); r, _ = rd(art('audio/sweep/rtl_mix.wav'))
    n = min(len(m), len(r)) // fs
    rms = lambda a: [float(np.sqrt(np.mean(a[i * fs:(i + 1) * fs] ** 2))) for i in range(n)]
    return rms(m), rms(r)

@slide("Sound was tested on its own. Comparing two recordings of gameplay would "
       "be comparing two different games, because of that randomness. So we "
       "recorded every command Mame's main processor sends to its sound board, "
       "with the exact time, and replayed those into ours. One real mistake "
       "showed up, found by reading Mame's source: the speech chip was a quarter "
       "as loud as it should be. Then a sweep through every sound command. "
       "Our loudness, in orange, is within six percent of Mame's in every one of "
       "the sixty six seconds. Here's a few seconds of our sound board.",
       audio_after=(art('audio/sweep/rtl_mix.wav'), 34.0, 6.0))
def s_sound():
    im, d = canvas()
    y = header(d, 'Listening properly', 'Step 17')
    m, r = sweep_rms()
    x0, y0, cw, ch = 180, y + 20, 1600, 520
    top = max(max(m), max(r)) * 1.1
    d.line([x0, y0 + ch, x0 + cw, y0 + ch], fill=DIM, width=2)
    for k in range(0, len(m) + 1, 10):
        xx = x0 + cw * k / len(m); d.text((xx - 14, y0 + ch + 12), f'{k}s', font=font(26), fill=DIM)
    for series, col, wd in ((m, DIM, 10), (r, ORANGE, 4)):
        pts = [(x0 + cw * (i + 0.5) / len(series), y0 + ch - ch * v / top) for i, v in enumerate(series)]
        d.line(pts, fill=col, width=wd, joint='curve')
    d.text((x0, y0 - 20), 'loudness, second by second', font=font(30, 'Demi'), fill=FG)
    for lx, lab, col in ((x0 + 1100, 'MAME', DIM), (x0 + 1300, 'ours', ORANGE)):
        d.rectangle([lx, y0 - 10, lx + 24, y0 + 14], fill=col)
        d.text((lx + 36, y0 - 20), lab, font=font(30, 'Demi'), fill=col)
    return im

@slide("Simulation proves the design works. Timing proves it works fast enough. "
       "The Pocket's chip runs this core at ninety six million ticks a second, so "
       "every signal gets about ten nanoseconds to get where it's going. The first "
       "compile missed by seven nanoseconds. Each fix exposed the next slowest "
       "path, a game of whack a mole, mostly inside the blitter, which had been "
       "written to be correct first and fast second. The last failure was the "
       "queue that holds the ROM image as it streams in from the S D card. "
       "Compile eight: every path met, with a little to spare. After every "
       "change, the frozen frames were checked again.")
def s_timing():
    im, d = canvas()
    y = header(d, 'Timing: fast enough, everywhere', 'Steps 11, 15, 16, 18')
    vals = [-7.35, -4.0, -2.36, -2.67, -2.12, -0.62, -0.36, 0.38]
    zx, zy, sc = 200, y + 120, 62
    d.line([zx - 40, zy, zx + 1560, zy], fill=DIM, width=3)
    for i, v in enumerate(vals):
        x = zx + i * 195
        col = GREEN if v >= 0 else RED
        y1 = zy - v * sc
        d.rectangle([x, min(zy, y1), x + 130, max(zy, y1)], fill=col)
        lab = f'{v:+.2f}'
        d.text((x + 65 - d.textlength(lab, font=font(32, 'Bold')) / 2,
                (y1 + 10) if v < 0 else (y1 - 48)), lab, font=font(32, 'Bold'), fill=col)
        d.text((x + 50, zy - 50 if v < 0 else zy + 12), f'#{i + 1}', font=font(28), fill=DIM)
    d.text((110, y - 20), 'worst slack per compile, nanoseconds (must be ≥ 0)', font=font(30, 'Demi'), fill=FG)
    return im

@slide("On a real Pocket, the ten megabyte ROM image arrives one byte every few "
       "ticks, and the loader cannot be told to wait. If memory is busy, a byte "
       "is simply lost. That exact problem cost an earlier core its first hardware "
       "test. So the whole machine was run again, exactly as the Pocket will run "
       "it: the image fed in at the Pocket's speed, through the real memory "
       "controller. It boots, matches Mame, and plays the attract mode game. "
       "These are frames from our simulated hardware.")
def s_system():
    im, d = canvas()
    y = header(d, 'Through the Pocket\'s real memory path', 'Steps 9 and 18')
    for i, n in enumerate([1249, 2999, 3499]):
        paste(im, rtl_frame(n).resize((540, 343), Image.LANCZOS), (110 + i * 580, y + 10), ORANGE)
    para(d, (110, y + 400), 'The 10.6 MB image in at the Pocket\'s own rate, read back byte for byte. '
         'Then the whole game, through the real memory controller.', size=38, width=1700)
    return im

@slide("So here's the scoreboard. Everything that can be proven without a Pocket "
       "has been. The picture, the blitter, the processor, the whole machine, the "
       "sound, the memory path, no flicker that could mark the Pocket's screen, "
       "and timing on every path.")
def s_score():
    im, d = canvas()
    y = header(d, 'The scoreboard', 'Step 19')
    rows = [('picture', 'pixel-identical to MAME on 16 frozen moments'),
            ('blitter', 'video memory identical after 2,080 drawing jobs'),
            ('processor', '69.6 million instructions identical, in order'),
            ('whole machine', 'boots to MAME-identical screens, real memory path'),
            ('sound', 'as loud as MAME\'s, every second, every command'),
            ('memory', '10.6 MB in at the Pocket\'s rate, read back exactly'),
            ('screen', 'no frame-to-frame flicker to mark the OLED'),
            ('timing', 'met on every path, every temperature')]
    for i, (a, b) in enumerate(rows):
        yy = y + i * 82
        d.line([(112, yy + 30), (128, yy + 46), (156, yy + 12)], fill=GREEN, width=8)
        d.text((180, yy + 4), a, font=font(40, 'Demi'), fill=FG)
        d.text((620, yy + 8), b, font=font(36), fill=DIM)
    return im

@slide("What is not proven yet is the real thing. Nobody has held a Pocket running "
       "this core. That's next: flash it, and read the debug panel the core draws "
       "on screen during bring up. And several topics here deserve their own, more "
       "technical videos: the processor that addresses single bits; the shift "
       "register eraser; why S D RAM loves bursts; lockstep testing against an "
       "emulator; caches; where arcade games get their randomness; comparing "
       "sounds; and timing closure.")
def s_next():
    im, d = canvas()
    y = header(d, 'Next: a real Pocket', 'What is not proven')
    para(d, (110, y), 'Nobody has held a Pocket running this yet. Next: flash it, and read the '
         'on-screen bring-up panel.', size=40, width=1700)
    d.text((110, y + 170), 'Deep dives to come', font=font(40, 'Bold'), fill=ORANGE)
    topics = ['a CPU that addresses bits, not bytes', 'the shift-register page eraser',
              'why SDRAM loves bursts', 'lockstep testing a CPU against MAME',
              'caches, and speed bugs that look fine', 'randomness from the video beam',
              'proving two recordings sound the same', 'timing closure']
    for i, t in enumerate(topics):
        d.text((110 + (i % 2) * 860, y + 250 + (i // 2) * 70), '• ' + t, font=font(34), fill=FG)
    return im

@slide("This core stands on a lot of other people's work. Mame's T unit driver, by "
       "Alex Pasadyn, Zsolt Vasvari, Ernesto Corvi and Aaron Giles. The sound "
       "chip cores by Jose Tejada, and the sixty-eight-oh-nine by Greg Miller. "
       "Marcus Andrade's Pocket platform and build tools. And the Smash T V and "
       "S T U N Runner cores it grew from. Thanks for watching.")
def s_credits():
    im, d = canvas()
    y = header(d, 'Thanks', 'Credits')
    rows = [('MAME midtunit driver', 'Alex Pasadyn, Zsolt Vasvari, Ernesto Corvi, Aaron Giles'),
            ('YM2151 and OKI6295 cores', 'Jose Tejada (jt51, jt6295)'),
            ('MC6809 core', 'Greg Miller'),
            ('Pocket platform and build', 'Marcus Andrade (OpenGateware, raetro/quartus)'),
            ('Grew from', 'the Smash TV and S.T.U.N. Runner Pocket cores'),
            ('NBA Jam', '© 1993 Midway; this video shows emulated and simulated frames')]
    for i, (a, b) in enumerate(rows):
        d.text((110, y + i * 100), a, font=font(38, 'Demi'), fill=ORANGE)
        d.text((720, y + 4 + i * 100), b, font=font(34), fill=FG)
    return im


# ------------------------------------------------------------ assembly
def run(*a):
    subprocess.run(a, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def dur(p):
    return float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                                          '-of', 'csv=p=0', p]).strip())

def main():
    only = set(sys.argv[1:])
    os.makedirs(WORK, exist_ok=True)
    segs = []
    for i, (fn, text, extra) in enumerate(S):
        name = f'{i:02d}_{fn.__name__[2:]}'
        png, aif, seg = (os.path.join(WORK, name + e) for e in ('.png', '.aiff', '.mp4'))
        segs.append(seg)
        if only and fn.__name__[2:] not in only and os.path.exists(seg): continue
        fn().save(png)
        subprocess.run(['say', '-v', VOICE, '-r', str(RATE), '-o', aif, text], check=True)
        t = dur(aif) + 1.0
        if extra:
            wav, start, length = extra
            clip = os.path.join(WORK, name + '_clip.wav')
            run('ffmpeg', '-y', '-ss', str(start), '-t', str(length), '-i', wav,
                '-af', f'volume=12dB,afade=t=in:d=0.2,afade=t=out:st={length - 0.5}:d=0.5', clip)
            both = os.path.join(WORK, name + '_both.wav')
            run('ffmpeg', '-y', '-i', aif, '-i', clip, '-filter_complex',
                '[0:a]aresample=48000,apad=pad_dur=0.6[a];[1:a]aresample=48000[b];[a][b]concat=n=2:v=0:a=1',
                both)
            aif, t = both, dur(both) + 0.6
        run('ffmpeg', '-y', '-loop', '1', '-framerate', '30', '-i', png, '-i', aif,
            '-filter_complex',
            f'[0:v]fade=t=in:d=0.35,fade=t=out:st={t - 0.35:.2f}:d=0.35,format=yuv420p[v];'
            f'[1:a]aresample=48000,aformat=channel_layouts=stereo,adelay=300|300,apad[a]',
            '-map', '[v]', '-map', '[a]', '-t', f'{t:.2f}', '-c:v', 'libx264', '-preset', 'medium',
            '-crf', '20', '-tune', 'stillimage', '-c:a', 'aac', '-b:a', '160k', '-ar', '48000', seg)
        print(f'{name}: {t:.1f} s', flush=True)
    lst = os.path.join(WORK, 'list.txt')
    open(lst, 'w').write(''.join(f"file '{s}'\n" for s in segs))
    out = os.path.join(OUT, 'nbajam_explainer.mp4')
    run('ffmpeg', '-y', '-f', 'concat', '-safe', '0', '-i', lst, '-c', 'copy', '-movflags', '+faststart', out)
    print(f'{out}: {dur(out):.1f} s')

if __name__ == '__main__':
    main()
