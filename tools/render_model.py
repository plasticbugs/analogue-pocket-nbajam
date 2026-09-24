#!/usr/bin/env python3
"""Reference renderer for the T-unit scan-out: VRAM + palette + the
TMS34010's display registers -> the frame MAME shows.

The executable statement of docs/hardware.md section 7.2:

  1. The frame is lines VEBLNK..VSBLNK-1 (20..273), dots HEBLNK*2..HSBLNK*2-1
     (100..499): 400 x 254.
  2. At the start of vblank the 34010 loads DPYADR from DPYSTRT.  On each
     visible line the address used is DPYADR, XORed with 0xfffc when
     DPYCTL.ORG = 0; after the line DPYADR steps by DUDATE = DPYCTL & 0x3fc
     (MAME tms34010.cpp scanline_callback, get_display_params).
  3. rowaddr = addr >> 4; coladdr = ((addr & 0x7c) << 4) | DPYTAP.
  4. Pixel x of the line = VRAM[((rowaddr << 9) & 0x3fe00) + ((coladdr*2 + x) & 0x1ff)]
     (midtunit_video_device::scanline_update), & 0x7fff.
  5. Colour = palette[index] as xRGB555, each 5-bit channel widened to 8 by
     (v << 3) | (v >> 2).

Checking it against MAME (tools/check_states.py): screen:pixels() at the end
of frame N returns the frame scanned during frame N-1 -- MAME's screen keeps
two bitmaps -- and that bitmap holds palette INDICES, coloured when it is read
out.  So MAME's picture N = the indices scanned from state N-1 (its DPYSTRT,
its VRAM) coloured with state N's palette.  Found on the "tonight's match-up"
screen, whose text blinks by palette.

    render_model.py state.bin [out.png]      render, and diff against MAME's pixels
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import pngio
from njstate import State, W, H

REG = dict(HESYNC=0, HEBLNK=1, HSBLNK=2, HTOTAL=3, VESYNC=4, VEBLNK=5, VSBLNK=6,
           VTOTAL=7, DPYCTL=8, DPYSTRT=9, DPYINT=10, DPYTAP=27, DPYADR=30)


def pal8(v):
    return (v << 3) | (v >> 2)


def line_addrs(io, dpystrt):
    """The display address of each visible line, from DPYSTRT at vblank."""
    dpyctl = io[REG['DPYCTL']]
    org = (dpyctl >> 10) & 1
    dudate = dpyctl & 0x3fc
    adr = dpystrt
    out = []
    for _ in range(H):
        a = adr if org else adr ^ 0xfffc
        out.append(a)
        if (adr & 3) == 0:
            adr = ((adr & 0xfffc) - dudate) & 0xffff | (dpystrt & 3)
        else:
            adr = (adr & 0xfffc) | ((adr - 1) & 3)
    return out


def render(st, dpystrt=None, palette=None):
    io = st.io
    pal = st.palette if palette is None else palette
    if dpystrt is None:
        dpystrt = io[REG['DPYSTRT']]
    tap = io[REG['DPYTAP']] & 0x3fff
    rgb = bytearray(W * H * 3)
    idx = [0] * (W * H)
    for y, a in enumerate(line_addrs(io, dpystrt)):
        row = ((a >> 4) << 9) & 0x3fe00
        col = ((((a & 0x7c) << 4) | tap) << 1)
        for x in range(W):
            p = st.vram[row + ((col + x) & 0x1ff)] & 0x7fff
            idx[y * W + x] = p
            c = pal[p]
            o = 3 * (y * W + x)
            rgb[o] = pal8((c >> 10) & 31)
            rgb[o + 1] = pal8((c >> 5) & 31)
            rgb[o + 2] = pal8(c & 31)
    return rgb, idx


def diff(a, b):
    return sum(1 for i in range(0, len(a), 3) if a[i:i + 3] != b[i:i + 3])


def main():
    st = State(sys.argv[1])
    rgb, _ = render(st)
    n = diff(rgb, st.pixels)
    tag = 'as dumped'
    if n:
        # the dump is taken at the end of the frame, after the game may have
        # written next frame's DPYSTRT: try the other page before reporting
        alt = st.io[REG['DPYSTRT']] ^ 0x1000
        rgb2, _ = render(st, alt)
        n2 = diff(rgb2, st.pixels)
        if n2 < n:
            rgb, n, tag = rgb2, n2, f'DPYSTRT {alt:04x} (other page)'
    print(f'{os.path.basename(sys.argv[1])}: {n} of {W * H} pixels differ from MAME ({tag}; '
          f'DPYSTRT {st.io[REG["DPYSTRT"]]:04x} DPYCTL {st.io[REG["DPYCTL"]]:04x})')
    if len(sys.argv) > 2:
        pngio.write(sys.argv[2], W, H, rgb)
    return 1 if n else 0


if __name__ == '__main__':
    sys.exit(main())
