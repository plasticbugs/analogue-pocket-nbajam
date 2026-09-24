#!/usr/bin/env python3
"""Check the .rom image nbajam.mra builds against MAME's own loaded regions.

MAME is the oracle for the ROM path too: tools/dump_regions.lua writes out the
bytes MAME hands to each chip, and this compares them with the image as the
core will see it -- as SDRAM words, each two image bytes with the first high
(target/pocket/nbajam_mem.sv).  A mismatch here means the core would be fed
different bytes than the game expects.

    REGION_DIR=dir tools/mame.sh -seconds_to_run 1 -autoboot_script tools/dump_regions.lua
    verify_rom.py <image.rom> <dir>
"""
import sys

GFX_BASE,  GFX_LEN  = 0x000000, 0x800000
PROG_BASE, PROG_LEN = 0x800000, 0x100000
OKI_BASE,  OKI_LEN  = 0x900000, 0x100000
SND_BASE,  SND_LEN  = 0xa00000, 0x020000
IMAGE_LEN = SND_BASE + SND_LEN


def fail(msg):
    print(f'FAIL: {msg}')
    sys.exit(1)


def words(image, base, n):
    """SDRAM word k of a region: first image byte high."""
    return [(image[base + 2 * k] << 8) | image[base + 2 * k + 1] for k in range(n)]


def first_diff(a, b):
    return next(i for i in range(min(len(a), len(b))) if a[i] != b[i])


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    image = open(sys.argv[1], 'rb').read()
    d = sys.argv[2].rstrip('/')
    video = open(f'{d}/video.bin', 'rb').read()
    prog = open(f'{d}/maincpu.bin', 'rb').read()
    oki = open(f'{d}/adpcm_oki.bin', 'rb').read()
    snd = open(f'{d}/adpcm_cpu.bin', 'rb').read()

    if len(image) != IMAGE_LEN:
        fail(f'image is {len(image)} bytes, expected {IMAGE_LEN}')

    # Graphics.  The TMS34010 reads word o as base[2o] | base[2o+1] << 8
    # (midtunit_gfxrom_r) and the blitter reads a little-endian bit stream
    # from the same bytes; both are "SDRAM word k = little-endian word k".
    n = GFX_LEN // 2
    got = words(image, GFX_BASE, n)
    want = [video[2 * k] | (video[2 * k + 1] << 8) for k in range(n)]
    if got != want:
        i = first_diff(got, want)
        fail(f'graphics word 0x{i:06x}: image {got[i]:04x}, MAME {want[i]:04x}')
    if any(video[GFX_LEN:]):
        fail('MAME video region has non-zero bytes past 8 MB; the core reads zero there')
    print(f'  graphics       {GFX_LEN:8d} bytes  identical to MAME (and MAME is zero above)')

    # TMS34010 program: ROM_REGION16_LE, word k = prog[2k] | prog[2k+1] << 8
    n = PROG_LEN // 2
    got = words(image, PROG_BASE, n)
    want = [prog[2 * k] | (prog[2 * k + 1] << 8) for k in range(n)]
    if got != want:
        i = first_diff(got, want)
        fail(f'program word 0x{i:05x}: image {got[i]:04x}, MAME {want[i]:04x}')
    print(f'  34010 program  {PROG_LEN:8d} bytes  identical to MAME')

    # OKI region, byte for byte
    if image[OKI_BASE:OKI_BASE + OKI_LEN] != oki:
        i = first_diff(image[OKI_BASE:OKI_BASE + OKI_LEN], oki)
        fail(f'OKI byte 0x{i:05x} differs')
    print(f'  OKI samples    {OKI_LEN:8d} bytes  identical to MAME')

    # 6809: the region holds u3 at 0x10000 and again at 0x30000
    u3 = image[SND_BASE:SND_BASE + SND_LEN]
    for at in (0x10000, 0x30000):
        if snd[at:at + SND_LEN] != u3:
            fail(f'6809 region at 0x{at:05x} differs from the image')
    print(f'  6809 program   {SND_LEN:8d} bytes  identical to both copies in MAME')
    print('PASS')


if __name__ == '__main__':
    main()
