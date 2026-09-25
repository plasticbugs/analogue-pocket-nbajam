// Pocket memory gate: push an image through nbajam_mem's download port at the
// APF loader's rate, then read every region back through the core's ports
// and compare.  Then the SRAM self-test port.
//
//   obj_mem/Vtb_mem_top [rom] [-gap N] [-hold N] [-quick]
//
// With no rom a pseudo-random image is used, which is a harder test than a
// real one (no runs of equal words to hide a dropped or merged write) and
// needs nothing the repo may not hold.
//
// -gap   clocks between download bytes.  The loader delivers one per 8;
//        smaller is harder.
// -hold  clocks the write strobe is held high.  The Pocket holds it for 4;
//        anything that counts on the strobe's level fails here (METHODOLOGY 5.8).
//
// The layout must match target/pocket/nbajam_mem.sv and nbajam.mra.
#include "Vtb_mem_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static Vtb_mem_top *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

static const uint32_t IMG = 0xa20000, SDRAM_BYTES = 0xa00000, OKI_B = 0x900000, SROM_B = 0xa00000;
static std::vector<uint8_t> rom;
static uint16_t be16(uint32_t o) { return (uint16_t(rom[o]) << 8) | rom[o + 1]; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int gap = 8, hold = 4; bool quick = false; std::string path;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-gap" && i + 1 < argc) gap = atoi(argv[++i]);
        else if (a == "-hold" && i + 1 < argc) hold = atoi(argv[++i]);
        else if (a == "-quick") quick = true;
        else if (a[0] != '+' && a[0] != '-') path = a;
    }
    if (hold >= gap) hold = gap - 1;
    if (hold < 1) hold = 1;

    rom.resize(IMG);
    if (!path.empty()) {
        FILE *f = fopen(path.c_str(), "rb");
        if (!f || fread(rom.data(), 1, IMG, f) != IMG) { fprintf(stderr, "cannot read %u bytes from %s\n", IMG, path.c_str()); return 2; }
        fclose(f);
    } else {
        uint32_t x = 0x2545F491;
        for (auto &b : rom) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; b = uint8_t(x >> 11); }
    }

    dut = new Vtb_mem_top;
    dut->init = 1; dut->rd_late = 1; dut->burst_slow = 0;
    dut->burst_fast = getenv("BURST_FAST") ? atoi(getenv("BURST_FAST")) : 1;
    dut->burst_fast_wr = getenv("BURST_FAST_WR") ? atoi(getenv("BURST_FAST_WR")) : dut->burst_fast;
    printf("bursts: %s\n", dut->burst_fast ? "one word a clock" : "one word every 2 clocks");
    dut->dl_we = 0; dut->dl_active = 1; dut->tst_hold = 1;
    dut->sd_req = dut->b_req = dut->oki_req = dut->srom_req = 0;
    for (int i = 0; i < 16; i++) tick();
    dut->init = 0;
    long t = 0; while (!dut->ready && t++ < 200000) tick();
    printf("sdram ready after %ld clocks\n", t);
    if (!dut->ready) { printf("FAIL  the controller never came ready\n"); return 1; }

    printf("downloading %u bytes, one per %d clocks, strobe held %d...\n", IMG, gap, hold);
    for (uint32_t a = 0; a < IMG; a++) {
        dut->dl_addr = a; dut->dl_data = rom[a]; dut->dl_we = 1;
        for (int i = 0; i < hold; i++) tick();
        dut->dl_we = 0;
        for (int i = hold; i < gap; i++) tick();
    }
    for (int i = 0; i < 2000; i++) tick();
    dut->dl_active = 0;

    long bad = 0, checked = 0;
    auto fail = [&](const char *port, uint32_t idx, uint32_t got, uint32_t want) {
        if (bad < 12) printf("  %-5s [%06X] got %04X want %04X\n", port, idx, got, want);
        bad++;
    };
    const uint32_t step = quick ? 61 : 1;       // a prime stride still visits every row

    // the CPU's port, over the whole 10 MB of SDRAM the image fills
    for (uint32_t w = 0; w < SDRAM_BYTES / 2; w += step) {
        dut->sd_addr = w; dut->sd_we = 0; dut->sd_be = 3; dut->sd_req = 1;
        int g = 0; while (!dut->sd_ack && g++ < 4000) tick();
        dut->sd_req = 0; tick();
        checked++; if (dut->sd_q != be16(2 * w)) fail("sd", w, dut->sd_q, be16(2 * w));
    }
    // the OKI's bytes
    for (uint32_t b = 0; b < 0x100000; b += step) {
        dut->oki_addr = b; dut->oki_req = 1;
        int g = 0; while (!dut->oki_ack && g++ < 4000) tick();
        dut->oki_req = 0; tick();
        checked++; if (dut->oki_q != rom[OKI_B + b]) fail("oki", b, dut->oki_q, rom[OKI_B + b]);
    }
    // the burst port: 512 words at a time over the graphics
    for (uint32_t w = 0; w + 512 <= 0x400000; w += 512 * (quick ? 61 : 1)) {
        dut->b_addr = w; dut->b_len = 512; dut->b_req = 1;
        int got = 0, g = 0;
        while (!dut->b_done && g++ < 40000) {
            tick();
            if (dut->b_wr) {
                uint16_t want = be16(2 * (w + dut->b_idx));
                checked++; if (dut->b_data != want) fail("burst", w + dut->b_idx, dut->b_data, want);
                got++;
            }
        }
        if (got != 512) fail("burst", w, got, 512);
        dut->b_req = 0;
        for (int i = 0; i < 4; i++) tick();
    }
    printf("game recognised: %s\n", dut->game_te ? "Tournament Edition" : "NBA Jam (or unknown)");
    if (getenv("EXPECT_TE") && atoi(getenv("EXPECT_TE")) != dut->game_te) { bad++; printf("  game recognition wrong\n"); }
    printf("SDRAM: %ld words checked through the core's ports, %ld wrong\n", checked, bad);

    // The power-on self-test, as the Pocket runs it: after the download, before
    // the sound CPU reads a byte.  It must read back A55A 5AA5 AND leave the
    // program as it found it -- the first hardware build wrote over the 6809's
    // reset vector here and was silent, while its panel read a pass.
    long sbad = 0;
    dut->tst_hold = 0;
    { int g = 0; while (!dut->tst_done && g++ < 200000) tick(); }
    if (!dut->tst_done || dut->tst_rd0 != 0xA55A || dut->tst_rd1 != 0x5AA5) {
        sbad++; printf("  self-test: done %d, read back %04X %04X, want A55A 5AA5\n",
                       dut->tst_done, dut->tst_rd0, dut->tst_rd1);
    }
    // then the sound CPU's bytes, every one, out of the SRAM
    for (uint32_t a = 0; a < 0x20000; a++) {
        dut->srom_addr = a; dut->srom_req = 1;
        int g = 0; while (!dut->srom_ack && g++ < 4000) tick();
        dut->srom_req = 0; tick();
        if (dut->srom_q != rom[SROM_B + a]) { if (sbad < 8) printf("  srom [%05X] got %02X want %02X\n", a, dut->srom_q, rom[SROM_B + a]); sbad++; }
    }
    printf("SRAM:  %ld wrong\n", sbad);

    delete dut;
    if (bad || sbad) { printf("FAIL  what came back is not what was sent\n"); return 1; }
    printf("PASS  every region reads back byte-for-byte\n");
    return 0;
}
