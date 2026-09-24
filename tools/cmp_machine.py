#!/usr/bin/env python3
"""Compare the machine bench's frame_NNNNN.rgb (the picture scanned during
frame N) with MAME's picture N+1 from artifacts/states/state_{N+1}.bin, and
write both as PNGs side by side:  cmp_machine.py machine-dir states-dir N [N...]"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import pngio
from njstate import State, W, H

def main():
    mdir, sdir = sys.argv[1], sys.argv[2]
    bad_any = 0
    for n in map(int, sys.argv[3:]):
        got = open(f'{mdir}/frame_{n:05d}.rgb', 'rb').read()
        st = State(f'{sdir}/state_{n + 1:05d}.bin')
        bad = sum(1 for i in range(0, len(got), 3) if got[i:i + 3] != st.pixels[i:i + 3])
        side = bytearray(W * 2 * H * 3)
        for y in range(H):
            side[3 * (y * 2 * W):3 * (y * 2 * W + W)] = got[3 * y * W:3 * (y + 1) * W]
            side[3 * (y * 2 * W + W):3 * (y * 2 * W + 2 * W)] = st.pixels[3 * y * W:3 * (y + 1) * W]
        pngio.write(f'{mdir}/cmp_{n:05d}.png', 2 * W, H, side)
        print(f'frame {n}: {bad} of {W * H} pixels differ from MAME picture {n + 1}  (cmp_{n:05d}.png: RTL left, MAME right)')
        bad_any += bad
    return 1 if bad_any else 0

if __name__ == '__main__':
    sys.exit(main())
