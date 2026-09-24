// Frozen-state bench for rtl/tunit_dma.sv on the real SDRAM controller.
//
//   obj/Vtb_blit_top image.rom state_A.bin events_B.txt state_B.bin
//
// Preloads the chip with the graphics ROM (and, above it, the 34010 program,
// as the real SDRAM holds it, so reads past 8 MB are really masked) and
// state A's VRAM; replays the frame's writes -- blitter registers through
// the register port, waiting for the blitter to go idle before each write as
// MAME's instant blits imply; CPU VRAM writes and the shift-register page
// clear applied to the chip directly -- then compares VRAM with state B.
// Prints the clocks the blitter was busy: at 96 MHz a frame is 1,754,925.
#include "Vtb_blit_top.h"
#include "Vtb_blit_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>

static Vtb_blit_top *dut;
static uint64_t clocks = 0, busy_clocks = 0;
static void tick() {
    dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); clocks++;
    if (dut->busy) busy_clocks++;
}
static uint16_t *mem() { return dut->rootp->tb_blit_top__DOT__chip__DOT__mem.data(); }

static const uint32_t VRAM_W = 0x800000, NPIX = 524288;

struct State {
    std::vector<uint16_t> io, dma, vram;
    uint16_t control;
    bool load(const char *path) {
        FILE *f = fopen(path, "rb");
        if (!f) return false;
        std::vector<uint8_t> d;
        uint8_t buf[65536]; size_t n;
        while ((n = fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n);
        fclose(f);
        if (d.size() < 12 || memcmp(d.data(), "NJST", 4)) return false;
        auto u16 = [&](size_t o) { return uint16_t(d[o] | (d[o + 1] << 8)); };
        size_t o = 12;
        io.resize(32); for (int i = 0; i < 32; i++, o += 2) io[i] = u16(o);
        control = u16(o); o += 2;
        dma.resize(18); for (int i = 0; i < 18; i++, o += 2) dma[i] = u16(o);
        o += 65536;                                  // palette
        vram.resize(NPIX); for (uint32_t i = 0; i < NPIX; i++, o += 2) vram[i] = u16(o);
        return true;
    }
};

static void wait_idle() { int g = 0; while (dut->busy && g++ < 20000000) tick(); }

static void reg_write(int r, uint16_t d, uint16_t mask) {
    wait_idle();
    dut->reg_wr = 1; dut->reg_addr = r; dut->reg_wdata = d;
    dut->reg_be = ((mask & 0xff) ? 1 : 0) | ((mask & 0xff00) ? 2 : 0);
    tick();
    dut->reg_wr = 0;
    tick();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: %s image.rom state_A events_B state_B\n", argv[0]); return 2; }
    State A, B;
    if (!A.load(argv[2]) || !B.load(argv[4])) { fprintf(stderr, "cannot read states\n"); return 2; }

    dut = new Vtb_blit_top;
    // chip contents: the image's first 9 MB word for word (graphics, then the
    // program), then state A's VRAM
    {
        FILE *f = fopen(argv[1], "rb");
        if (!f) { fprintf(stderr, "cannot read %s\n", argv[1]); return 2; }
        std::vector<uint8_t> img(0x900000);
        if (fread(img.data(), 1, img.size(), f) != img.size()) { fprintf(stderr, "short image\n"); return 2; }
        fclose(f);
        for (uint32_t w = 0; w < 0x480000; w++) mem()[w] = (img[2 * w] << 8) | img[2 * w + 1];
    }
    for (uint32_t p = 0; p < NPIX; p++) mem()[VRAM_W + p] = A.vram[p];

    dut->init = 1; for (int i = 0; i < 16; i++) tick();
    dut->init = 0;
    while (!dut->ready) tick();

    // the blitter's registers as they stood at A (reg 0..15 through the
    // port; the clip pseudo-registers by writing 12/13 with CONFIG bit 5 clear)
    auto setreg = [&](int r, uint16_t v) { reg_write(r, v, 0xffff); };
    setreg(15, 0x0000);                                  // offsets 12/13 -> LEFT/RIGHTCLIP
    setreg(12, A.dma[16]); setreg(13, A.dma[17]);
    setreg(15, 0x0020);                                  // offsets 12/13 -> TOP/BOTCLIP
    for (int r = 0; r < 15; r++) if (r != 1) setreg(r, A.dma[r]);
    setreg(15, A.dma[15]);

    uint16_t control = A.control;
    std::vector<uint16_t> shiftreg(1024, 0);
    uint64_t start = clocks, blits = 0;
    busy_clocks = 0;
    std::ifstream ev(argv[3]);
    std::string line;
    while (std::getline(ev, line)) {
        std::istringstream is(line);
        std::string k; is >> k;
        if (k == "R") {
            int r; std::string d, m; is >> r >> d >> m;
            uint16_t dv = std::stoul(d, nullptr, 16), mv = std::stoul(m, nullptr, 16);
            if (r == 1 && (dv & 0x8000)) blits++;
            reg_write(r, dv, mv);
        } else if (k == "C") {
            std::string d, m; is >> d >> m;
            uint16_t dv = std::stoul(d, nullptr, 16), mv = std::stoul(m, nullptr, 16);
            control = (control & ~mv) | (dv & mv);
        } else if (k == "V") {
            std::string o, d, m; is >> o >> d >> m;
            uint32_t off = std::stoul(o, nullptr, 16); uint16_t dv = std::stoul(d, nullptr, 16), mv = std::stoul(m, nullptr, 16);
            wait_idle();
            uint16_t *v = mem() + VRAM_W; uint32_t p = 2 * off; uint16_t pal = dut->palette;
            if (control & 0x20) {
                if (mv & 0x00ff) v[p]     = (dv & 0xff) | ((pal & 0xff) << 8);
                if (mv & 0xff00) v[p + 1] = ((dv >> 8) & 0xff) | (pal & 0xff00);
            } else {
                if (mv & 0x00ff) v[p]     = (v[p] & 0xff) | ((dv & 0xff) << 8);
                if (mv & 0xff00) v[p + 1] = (v[p + 1] & 0xff) | (dv & 0xff00);
            }
        } else if (k == "T") {
            std::string a; is >> a; uint32_t p = std::stoul(a, nullptr, 16) >> 3;
            wait_idle();
            for (int i = 0; i < 1024; i++) shiftreg[i] = mem()[VRAM_W + ((p + i) & 0x7ffff)];
        } else if (k == "S") {
            std::string a, pt, dd; is >> a >> pt >> dd;
            uint32_t daddr = std::stoul(a, nullptr, 16), pitch = std::stoul(pt, nullptr, 16), dydx = std::stoul(dd, nullptr, 16);
            wait_idle();
            for (uint32_t i = 0; i < (dydx >> 16); i++) {
                uint32_t p = (daddr + i * pitch) >> 3;
                for (int k2 = 0; k2 < 1024; k2++) mem()[VRAM_W + ((p + k2) & 0x7ffff)] = shiftreg[k2];
            }
        }
    }
    wait_idle();
    for (int i = 0; i < 64; i++) tick();

    long bad = 0;
    for (uint32_t p = 0; p < NPIX; p++) {
        uint16_t got = mem()[VRAM_W + p];
        if (got != B.vram[p]) {
            if (bad < 10) printf("  pixel %05x (row %u x %u): rtl %04x  MAME %04x\n", p, p >> 9, p & 511, got, B.vram[p]);
            bad++;
        }
    }
    printf("%llu blits, blitter busy %llu clocks (%.1f%% of a 96 MHz frame), %ld of %u VRAM pixels differ, skip-mode %u\n",
           (unsigned long long)blits, (unsigned long long)busy_clocks, 100.0 * busy_clocks / 1754925.0,
           bad, NPIX, dut->stat_skipmode);
    (void)start;
    delete dut;
    return bad ? 1 : 0;
}
