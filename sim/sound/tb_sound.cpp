// The sound board alone, driven by MAME's own command stream at MAME's times
// (tools/snd_log.lua), METHODOLOGY 5.10.  Writes the mix and each chip:
//
//   obj/Vtb_sound_top image.rom cmds.txt seconds outdir
//
// -> outdir/rtl_mix.wav, rtl_ym.wav (L+R), rtl_oki.wav, rtl_dac.wav, 48 kHz,
// each chip at its own MAME full scale (so rtl_mix = 0.1 ym + 0.1 dac + 0.15 oki).
#include "Vtb_sound_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <cmath>

static void write_wav(const std::string &path, const std::vector<int16_t> &s) {
    FILE *f = fopen(path.c_str(), "wb");
    uint32_t n = s.size() * 2, sr = 48000, br = 96000, x;
    fwrite("RIFF", 1, 4, f); x = 36 + n; fwrite(&x, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    x = 16; fwrite(&x, 4, 1, f); uint16_t h = 1; fwrite(&h, 2, 1, f); fwrite(&h, 2, 1, f);
    fwrite(&sr, 4, 1, f); fwrite(&br, 4, 1, f); h = 2; fwrite(&h, 2, 1, f); h = 16; fwrite(&h, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&n, 4, 1, f); fwrite(s.data(), 2, s.size(), f); fclose(f);
}
static int16_t sat(double v) { v = std::round(v); return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: %s image.rom cmds.txt seconds outdir\n", argv[0]); return 2; }
    std::vector<uint8_t> img(0xa20000);
    FILE *f = fopen(argv[1], "rb");
    if (!f || fread(img.data(), 1, img.size(), f) != img.size()) { fprintf(stderr, "cannot read image\n"); return 2; }
    fclose(f);
    struct Cmd { uint64_t clk; uint16_t data; };
    std::vector<Cmd> cmds;
    f = fopen(argv[2], "r");
    double t; unsigned off, data, mask;
    while (fscanf(f, "%lf %x %x %x", &t, &off, &data, &mask) == 4)
        if ((off & 0xf0) == 0x30) cmds.push_back({(uint64_t)(t * 96e6 + 0.5), (uint16_t)data});
    fclose(f);
    double secs = atof(argv[3]);
    std::string out = argv[4];

    auto *dut = new Vtb_sound_top;
    uint64_t clk = 0;
    auto tick = [&]() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); clk++; };
    dut->rst = 1; dut->cmd_strobe = 0; dut->cmd_reset = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 0;
    clk = 0;
    size_t ci = 0;
    int rw = 0, ow = 0;
    std::vector<int16_t> mix, ym, oki, dac;
    uint64_t end = (uint64_t)(secs * 96e6);
    while (clk < end) {
        dut->cmd_strobe = 0;
        if (ci < cmds.size() && clk >= cmds[ci].clk) {
            dut->cmd = cmds[ci].data & 0xff;
            dut->cmd_reset = !(cmds[ci].data & 0x100);
            dut->cmd_strobe = 1;
            ci++;
        }
        tick();
        if (dut->rom_req && !dut->rom_ack) { if (++rw == 3) { dut->rom_q = img[0xa00000 + dut->rom_addr]; dut->rom_ack = 1; rw = 0; } }
        else { dut->rom_ack = 0; rw = 0; }
        if (dut->oki_req && !dut->oki_ack) { if (++ow == 12) { dut->oki_q = img[0x900000 + dut->oki_addr]; dut->oki_ack = 1; ow = 0; } }
        else { dut->oki_ack = 0; ow = 0; }
        if (clk % 2000 == 0) {
            mix.push_back(dut->snd);
            ym.push_back(sat(((int16_t)dut->ym_l + (int16_t)dut->ym_r) * 0.5));
            int o = dut->oki_o; if (o & 0x2000) o -= 0x4000;
            oki.push_back(sat(o * 16.0 * 0.25));          // /4 so four voices fit
            dac.push_back((int16_t)dut->dac_o);
        }
    }
    write_wav(out + "/rtl_mix.wav", mix);
    write_wav(out + "/rtl_ym.wav", ym);
    write_wav(out + "/rtl_oki.wav", oki);
    write_wav(out + "/rtl_dac.wav", dac);
    printf("%zu commands replayed over %.1f s, 6809 ROM stalls %u\n", ci, secs, dut->stalls);
    delete dut;
    return 0;
}
