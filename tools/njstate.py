"""Read a state_NNNNN.bin written by tools/dump_state.lua."""
import struct

W, H = 400, 254


class State:
    def __init__(self, path):
        d = open(path, 'rb').read()
        if d[:4] != b'NJST':
            raise ValueError(f'{path}: not an NJST dump')
        self.version, self.frame = struct.unpack_from('<II', d, 4)
        o = 12
        self.io = list(struct.unpack_from('<32H', d, o)); o += 64
        self.control = struct.unpack_from('<H', d, o)[0]; o += 2
        self.dma = list(struct.unpack_from('<18H', d, o)); o += 36
        self.palette = list(struct.unpack_from('<32768H', d, o)); o += 65536
        self.vram = list(struct.unpack_from('<524288H', d, o)); o += 1048576
        px = struct.unpack_from(f'<{W * H}I', d, o)
        self.pixels = bytearray(W * H * 3)
        for i, v in enumerate(px):
            self.pixels[3 * i:3 * i + 3] = bytes(((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff))
