#!/usr/bin/env python3
"""The reference models against every captured state (tools/dump_state.lua):

  scan-out  render_model(state N-1, palette of N) == MAME's picture of frame N
            (render_model.py says why)
  blitter   dma_model(state N-1 + events_N) == state N's VRAM, every pixel

    check_states.py image.rom artifacts/states
"""
import sys, os, glob, re
sys.path.insert(0, os.path.dirname(__file__))
from njstate import State, W, H
import render_model, dma_model, pngio


def main():
    image, d = sys.argv[1], sys.argv[2].rstrip('/')
    gfx = dma_model.load_gfx(image)
    fails = 0
    for ev in sorted(glob.glob(f'{d}/events_*.txt')):
        n = int(re.search(r'events_(\d+)', ev).group(1))
        a, b = State(f'{d}/state_{n - 1:05d}.bin'), State(f'{d}/state_{n:05d}.bin')
        rgb, _ = render_model.render(a, palette=b.palette)
        px = render_model.diff(rgb, b.pixels)
        pngio.write(f'{d}/model_{n:05d}.png', W, H, rgb)
        pngio.write(f'{d}/mame_{n:05d}.png', W, H, b.pixels)
        bl = dma_model.Blitter(gfx, list(a.vram), a.dma, a.control)
        dma_model.replay(bl, ev)
        vd = sum(1 for i in range(len(b.vram)) if bl.vram[i] != b.vram[i])
        ok = (px == 0 and vd == 0)
        fails += not ok
        print(f'frame {n:5d}: scan-out {px:6d} px differ   blitter {bl.blits:4d} blits '
              f'{bl.pixels:7d} px -> {vd:6d} VRAM px differ   {"ok" if ok else "FAIL"}')
    print('PASS' if not fails else f'FAIL ({fails} frames)')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
