#!/usr/bin/env python3
"""Reference model of the T-unit DMA blitter and the CPU's VRAM port.

A transcription of midtunit_video_device::dma_w / dma_draw / midtunit_vram_w
(MAME 0.288, ref/mame/src/mame/midway/midtunit_v.cpp) -- read that code and
docs/hardware.md section 7 alongside this.  Replaying the writes MAME logged
between two dumps (tools/dump_state.lua, LOG=) onto the first dump's VRAM must
reproduce the second dump's VRAM exactly:

    dma_model.py image.rom state_A.bin events_B.txt state_B.bin

The graphics come from the core's own ROM image (tools/verify_rom.py proves it
identical to MAME's region); bytes past 8 MB read as zero, as in MAME's 12 MB
region.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from njstate import State

XPOSMASK, YPOSMASK = 0x3ff, 0x1ff
GFX_LEN = 0x800000

# (zero, nonzero) per pixel op, from INIT_TEMPLATED_DMA_DRAW_GROUP
SKIP, COPY, COLOR = 0, 1, 2
OPS = {0: None, 1: (COPY, SKIP), 2: (SKIP, COPY), 3: (COPY, COPY),
       4: (COLOR, SKIP), 5: (COLOR, SKIP), 6: (COLOR, COPY), 7: (COLOR, COPY),
       8: (SKIP, COLOR), 9: (COPY, COLOR), 10: (SKIP, COLOR), 11: (COPY, COLOR),
       12: (COLOR, COLOR), 13: (COLOR, COLOR), 14: (COLOR, COLOR), 15: (COLOR, COLOR)}


def c_div(a, b):
    """C integer division (truncates toward zero); METHODOLOGY 5.13."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


class Blitter:
    def __init__(self, gfx, vram, regs, control):
        self.gfx = gfx                      # bytes, 8 MB
        self.vram = vram                    # list of 512K pixels
        self.regs = list(regs)              # 18 entries
        self.control = control
        self.blits = 0
        self.pixels = 0                     # MAME's timing count

    def rom(self, i):
        return self.gfx[i] if 0 <= i < GFX_LEN else 0

    def extract(self, o, mask):
        b = o >> 3
        return ((self.rom(b) | (self.rom(b + 1) << 8)) >> (o & 7)) & mask

    # ---------------------------------------------------------- CPU port
    def control_w(self, data, mask):
        self.control = (self.control & ~mask) | (data & mask)

    def vram_w(self, o, data, mask):
        v, p = self.vram, 2 * o
        pal = self.regs[8]
        if (self.control >> 5) & 1:
            if mask & 0x00ff:
                v[p] = (data & 0xff) | ((pal & 0xff) << 8)
            if mask & 0xff00:
                v[p + 1] = ((data >> 8) & 0xff) | (pal & 0xff00)
        else:
            if mask & 0x00ff:
                v[p] = (v[p] & 0xff) | ((data & 0xff) << 8)
            if mask & 0xff00:
                v[p + 1] = (v[p + 1] & 0xff) | (data & 0xff00)

    # ------------------------------------------- shift-register transfers
    def to_shiftreg(self, addr):
        """midtunit to_shiftreg: 1024 pixels from pixel address addr >> 3"""
        p = addr >> 3
        self.shiftreg = [self.vram[(p + i) & 0x7ffff] for i in range(1024)]

    def fill_shiftreg(self, daddr, pitch, dydx):
        """FILL L with DPYCTL.SRT: one from_shiftreg per row (the game's
        fills are one 16-bit pixel wide), each copying 1024 pixels."""
        rows = dydx >> 16
        for i in range(rows):
            p = ((daddr + i * pitch) & 0xffffffff) >> 3
            for k in range(1024):
                self.vram[(p + k) & 0x7ffff] = self.shiftreg[k]

    # ---------------------------------------------------------- DMA port
    def dma_w(self, offset, data, mask):
        regbank = (self.regs[15] >> 5) & 1
        regnum = offset if regbank else {12: 16, 13: 17}.get(offset, offset)
        self.regs[regnum] = (self.regs[regnum] & ~mask) | (data & mask)
        if regnum != 1:
            return
        command = self.regs[1]
        if not (command & 0x8000):
            return
        self.start(command)

    def start(self, command):
        r = self.regs
        bpp = (command >> 12) & 7
        st = dict(xpos=r[4] & XPOSMASK, ypos=r[5] & YPOSMASK, width=r[6] & 0x3ff,
                  height=r[7] & 0x3ff, palette=r[8] & 0x7f00, color=r[9] & 0xff,
                  yflip=(command & 0x20) >> 5, preskip=(command >> 8) & 3,
                  postskip=(command >> 10) & 3,
                  xstep=r[10] if r[10] else 0x100, ystep=r[11] if r[11] else 0x100,
                  topclip=r[12] & 0x1ff, botclip=r[13] & 0x1ff,
                  leftclip=r[16] & 0x3ff, rightclip=r[17] & 0x3ff)
        gfxoffset = r[2] | (r[3] << 16)
        if (command & 0x0f) == 0x0c:
            gfxoffset = 0
        if gfxoffset >= 0x2000000:          # !m_gfx_rom_large
            gfxoffset -= 0x2000000
        if gfxoffset >= 0xf8000000:
            gfxoffset -= 0xf8000000
        self.blits += 1
        if gfxoffset >= 0x10000000:
            return
        st['offset'] = gfxoffset
        if command & 0x40:
            st['startskip'] = r[0] & 0xff
            st['endskip'] = r[0] >> 8
        else:
            st['startskip'] = 0
            st['endskip'] = r[0]
        scale = not (st['xstep'] == 0x100 and st['ystep'] == 0x100)
        ops = OPS[command & 0x0f]
        if ops is not None:
            self.draw(st, 8 if bpp == 0 else bpp, bool(command & 0x10), bool(command & 0x80),
                      scale, ops[0], ops[1])
        if not scale:
            self.pixels += st['width'] * st['height']
        elif st['xstep'] and st['ystep']:
            self.pixels += c_div(st['width'] << 8, st['xstep']) * c_div(st['height'] << 8, st['ystep'])

    def draw(self, st, bpp, xflip, skip, scale, zero, nonzero):
        """dma_draw<BitsPerPixel, XFlip, Skip, Scale, Zero, NonZero>, line for line."""
        v = self.vram
        height = st['height'] << 8
        offset = st['offset']
        pal = st['palette']
        color = pal | st['color']
        sy = st['ypos']
        iy = 0
        mask = (1 << bpp) - 1
        xstep = st['xstep'] if scale else 0x100
        pre = post = 0
        while iy < height:
            startskip = st['startskip'] << 8
            endskip = st['endskip'] << 8
            width = st['width'] << 8
            sx = st['xpos']
            ix = 0
            o = offset
            clipped = False
            if skip:
                value = self.extract(o, 0xff)
                o += 8
                pre = (value & 0x0f) << (st['preskip'] + 8)
                tx = c_div(pre, xstep)
                sx = (sx - tx) & XPOSMASK if xflip else (sx + tx) & XPOSMASK
                ix += tx * xstep
                post = ((value >> 4) & 0x0f) << (st['postskip'] + 8)
                width -= post
                endskip -= post
            if sy < st['topclip'] or sy > st['botclip']:
                clipped = True
            if not clipped:
                if ix < startskip:
                    tx = c_div(startskip - ix, xstep) * xstep
                    ix += tx
                    o += (tx >> 8) * bpp
                if (width >> 8) > st['width'] - st['endskip']:
                    width = (st['width'] - st['endskip']) << 8
                base = sy * 512
                lc, rc = st['leftclip'], st['rightclip']
                while ix < width:
                    if lc <= sx <= rc:
                        if zero == nonzero:
                            if zero == COLOR:
                                v[base + sx] = color
                            elif zero == COPY:
                                v[base + sx] = self.extract(o, mask) | pal
                        else:
                            pixel = self.extract(o, mask)
                            if pixel:
                                if nonzero == COLOR:
                                    v[base + sx] = color
                                elif nonzero == COPY:
                                    v[base + sx] = pixel | pal
                            else:
                                if zero == COLOR:
                                    v[base + sx] = color
                                elif zero == COPY:
                                    v[base + sx] = pal
                    sx = (sx - 1) & XPOSMASK if xflip else (sx + 1) & XPOSMASK
                    if not scale:
                        ix += 0x100
                        o += bpp
                    else:
                        tx = ix >> 8
                        ix += xstep
                        tx = (ix >> 8) - tx
                        o += bpp * tx
            # clipy:
            sy = (sy - 1) & YPOSMASK if st['yflip'] else (sy + 1) & YPOSMASK
            if not scale:
                iy += 0x100
                width = st['width']
                if skip:
                    offset += 8
                    width -= (pre + post) >> 8
                    if width > 0:
                        offset += width * bpp
                else:
                    offset += width * bpp
            else:
                ty = iy >> 8
                iy += st['ystep']
                ty = (iy >> 8) - ty
                if not skip:
                    offset += ty * st['width'] * bpp
                elif ty:
                    ty -= 1
                    o = offset + 8
                    width = st['width'] - ((pre + post) >> 8)
                    if width > 0:
                        o += width * bpp
                    while ty:
                        ty -= 1
                        value = self.extract(o, 0xff)
                        o += 8
                        pre = (value & 0x0f) << st['preskip']
                        post = ((value >> 4) & 0x0f) << st['postskip']
                        width = st['width'] - pre - post
                        if width > 0:
                            o += width * bpp
                    offset = o


def load_gfx(image_path):
    """The graphics region as MAME's byte order, from the core's image
    (SDRAM word k = {byte 2k+1, byte 2k}, first image byte high)."""
    img = open(image_path, 'rb').read(GFX_LEN)
    g = bytearray(GFX_LEN)
    g[0::2] = img[1::2]
    g[1::2] = img[0::2]
    return bytes(g)


def replay(bl, events_path, stop_frame=None):
    for line in open(events_path):
        p = line.split()
        if p[0] == 'R':
            bl.dma_w(int(p[1]), int(p[2], 16), int(p[3], 16))
        elif p[0] == 'V':
            bl.vram_w(int(p[1], 16), int(p[2], 16), int(p[3], 16))
        elif p[0] == 'C':
            bl.control_w(int(p[1], 16), int(p[2], 16))
        elif p[0] == 'T':
            bl.to_shiftreg(int(p[1], 16))
        elif p[0] == 'S':
            bl.fill_shiftreg(int(p[1], 16), int(p[2], 16), int(p[3], 16))
        elif p[0] == 'F' and stop_frame is not None and int(p[1]) >= stop_frame:
            break


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    gfx = load_gfx(sys.argv[1])
    a, b = State(sys.argv[2]), State(sys.argv[4])
    bl = Blitter(gfx, list(a.vram), a.dma, a.control)
    replay(bl, sys.argv[3])
    bad = [i for i in range(len(b.vram)) if bl.vram[i] != b.vram[i]]
    print(f'frames {a.frame}->{b.frame}: {bl.blits} blits, {bl.pixels} pixels (MAME timing count), '
          f'{len(bad)} of {len(b.vram)} VRAM pixels differ')
    for i in bad[:10]:
        print(f'   pixel {i:06x} (row {i >> 9}, x {i & 511}): model {bl.vram[i]:04x}  MAME {b.vram[i]:04x}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
