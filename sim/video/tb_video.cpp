// Frozen-state bench for rtl/tunit_video.sv on the real SDRAM controller.
//
//   obj/Vtb_video_top state_A.bin state_B.bin [out.png-ish raw]
//
// MAME's picture of frame N is frame N-1's scan (state A: its VRAM and
// display registers) coloured with state B's palette (tools/render_model.py
// says why).  So: VRAM and registers from A, palette from B, run to the
// VSBLNK reload, capture the next frame's 400 x 254 and compare every RGB
// value with B's pixels.
#include "Vtb_video_top.h"
#include "Vtb_video_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <vector>

static Vtb_video_top *dut;
static int div12 = 0;
static void tick() {
    dut->cen_dot = (div12 == 0);
    dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval();
    div12 = (div12 == 11) ? 0 : div12 + 1;
}
static uint16_t *mem() { return dut->rootp->tb_video_top__DOT__chip__DOT__mem.data(); }

struct State {
    std::vector<uint16_t> io, pal, vram; std::vector<uint32_t> px;
    bool load(const char *path) {
        FILE *f = fopen(path, "rb"); if (!f) return false;
        std::vector<uint8_t> d; uint8_t b[65536]; size_t n;
        while ((n = fread(b, 1, sizeof b, f)) > 0) d.insert(d.end(), b, b + n);
        fclose(f);
        if (d.size() < 12 || memcmp(d.data(), "NJST", 4)) return false;
        auto u16 = [&](size_t o) { return uint16_t(d[o] | (d[o + 1] << 8)); };
        size_t o = 12;
        io.resize(32); for (int i = 0; i < 32; i++, o += 2) io[i] = u16(o);
        o += 2 + 36;
        pal.resize(32768); for (int i = 0; i < 32768; i++, o += 2) pal[i] = u16(o);
        vram.resize(524288); for (int i = 0; i < 524288; i++, o += 2) vram[i] = u16(o);
        px.resize(400 * 254);
        for (int i = 0; i < 400 * 254; i++, o += 4) px[i] = d[o] | (d[o+1] << 8) | (d[o+2] << 16);
        return true;
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    State A, B;
    if (argc < 3 || !A.load(argv[1]) || !B.load(argv[2])) { fprintf(stderr, "usage: %s state_A state_B\n", argv[0]); return 2; }
    dut = new Vtb_video_top;
    for (int p = 0; p < 524288; p++) mem()[0x800000 + p] = A.vram[p];
    dut->init = 1; for (int i = 0; i < 24; i++) tick();
    dut->init = 0;
    while (!dut->ready) tick();
    for (int i = 0; i < 32768; i++) {
        dut->pal_we = 1; dut->pal_a = i; dut->pal_d = B.pal[i]; tick();
    }
    dut->pal_we = 0;
    const int regs[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 27};
    for (int r : regs) { dut->vreg_we = 1; dut->vreg_a = r; dut->vreg_d = A.io[r]; tick(); }
    dut->vreg_we = 0;

    // run through one VSBLNK reload (line 274) into the next frame
    int vsb = A.io[6] & 0x1ff, veb = A.io[5] & 0x1ff;
    long g = 0;
    while (dut->vline_o != vsb && g++ < 5000000) tick();
    while (dut->vline_o == vsb) tick();
    while (dut->vline_o != veb) tick();
    std::vector<uint32_t> got; got.reserve(400 * 254);
    int prev = -1;
    while ((int)got.size() < 400 * 254 && g++ < 50000000) {
        tick();
        if (div12 == 1 && dut->de) got.push_back(dut->rgb);   // just after a dot edge
        (void)prev;
    }
    long bad = 0;
    for (int i = 0; i < 400 * 254; i++) {
        if (got[i] != B.px[i]) {
            if (bad < 8) printf("  (%d,%d) rtl %06x MAME %06x\n", i % 400, i / 400, got[i], B.px[i]);
            bad++;
        }
    }
    printf("%zu pixels captured, %ld differ from MAME, late lines %u\n", got.size(), bad, dut->late);
    delete dut;
    return bad ? 1 : 0;
}
