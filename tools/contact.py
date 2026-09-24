#!/usr/bin/env python3
"""Tile PNGs into one contact sheet, half size: contact.py out.png a.png b.png ..."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import pngio

def main():
    out, files = sys.argv[1], sys.argv[2:]
    cols = 5
    imgs = [pngio.read(f) for f in files]
    w = max(i[0] for i in imgs) // 2; h = max(i[1] for i in imgs) // 2
    rows = (len(imgs) + cols - 1) // cols
    W, H = cols * w, rows * h
    buf = bytearray(W * H * 3)
    for k, (iw, ih, px) in enumerate(imgs):
        ox, oy = (k % cols) * w, (k // cols) * h
        for y in range(min(h, ih // 2)):
            for x in range(min(w, iw // 2)):
                s = ((2 * y) * iw + 2 * x) * 3
                d = ((oy + y) * W + ox + x) * 3
                buf[d:d + 3] = px[s:s + 3]
    pngio.write(out, W, H, buf)

if __name__ == '__main__':
    main()
