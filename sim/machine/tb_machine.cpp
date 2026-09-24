// The whole machine from reset, on the real SDRAM controller, with the image
// preloaded (no download) and the sound ROM answered as the SRAM would.
//
//   obj/Vtb_machine_top image.rom -frames N [-inputs script] [-snap f1,f2,...]
//                       [-out dir] [-wav file]
//
// Frames are counted as MAME counts them (the start of each vblank, the
// raster starting at line 274 as MAME's does), so frame N here is MAME's
// frame N.  -snap writes frame_NNNNN.rgb (400x254 RGB) of the picture
// SCANNED during that frame; MAME's screen:pixels() for frame N+1 is the same
// picture (tools/render_model.py says why).  Inputs: the same scripts as
// tools/inputs/*.txt, "frame port field value", MAME's field names.
#include "Vtb_machine_top.h"
#include "Vtb_machine_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <fstream>
#include <sstream>
#include <chrono>

static Vtb_machine_top *dut;
static uint64_t clocks = 0;
static uint16_t *mem() { return dut->rootp->tb_machine_top__DOT__chip__DOT__mem.data(); }

struct Ev { std::string port, field; int v; };

static int bit_of(const std::string &port, const std::string &f, int &which) {
    // which: 0 IN0, 1 IN1, 2 IN2
    static const std::map<std::string, int> in0 = {
        {"P1 Up", 0}, {"P1 Down", 1}, {"P1 Left", 2}, {"P1 Right", 3},
        {"P1 Shoot / Block", 4}, {"P1 Pass / Steal", 5}, {"P1 Turbo", 6},
        {"P2 Up", 8}, {"P2 Down", 9}, {"P2 Left", 10}, {"P2 Right", 11},
        {"P2 Shoot / Block", 12}, {"P2 Pass / Steal", 13}, {"P2 Turbo", 14}};
    static const std::map<std::string, int> in1 = {
        {"Coin 1", 0}, {"Coin 2", 1}, {"1 Player Start", 2}, {"Tilt", 3},
        {"Service Mode", 4}, {"2 Players Start", 5}, {"Service 1", 6},
        {"Coin 3", 7}, {"Coin 4", 8}, {"3 Players Start", 9}, {"4 Players Start", 10}};
    if (port == ":IN0" && in0.count(f)) { which = 0; return in0.at(f); }
    if (port == ":IN1" && in1.count(f)) { which = 1; return in1.at(f); }
    return -1;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string image, inputs, outdir = ".", wav;
    long frames = 10;
    std::set<long> snaps;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-frames" && i + 1 < argc) frames = atol(argv[++i]);
        else if (a == "-inputs" && i + 1 < argc) inputs = argv[++i];
        else if (a == "-out" && i + 1 < argc) outdir = argv[++i];
        else if (a == "-wav" && i + 1 < argc) wav = argv[++i];
        else if (a == "-snap" && i + 1 < argc) {
            std::stringstream ss(argv[++i]); std::string t;
            while (std::getline(ss, t, ',')) snaps.insert(atol(t.c_str()));
        } else if (a[0] != '-' && a[0] != '+') image = a;
    }
    std::vector<uint8_t> img(0xa20000);
    { FILE *f = fopen(image.c_str(), "rb");
      if (!f || fread(img.data(), 1, img.size(), f) != img.size()) { fprintf(stderr, "cannot read %s\n", image.c_str()); return 2; }
      fclose(f); }
    std::map<long, std::vector<Ev>> script;
    if (!inputs.empty()) {
        std::ifstream in(inputs); std::string line;
        while (std::getline(in, line)) {
            if (line.empty() || line[0] == '#') continue;
            std::istringstream is(line); long fr; std::string port; is >> fr >> port;
            std::string rest; std::getline(is, rest);
            size_t e = rest.find_last_not_of(" \t"); rest = rest.substr(0, e + 1);
            size_t sp = rest.find_last_of(' ');
            int v = atoi(rest.substr(sp + 1).c_str());
            std::string field = rest.substr(0, sp); field = field.substr(field.find_first_not_of(' '));
            script[fr].push_back({port, field, v});
        }
    }

    dut = new Vtb_machine_top;
    for (uint32_t w = 0; w < 0x510000; w++) mem()[w] = (img[2 * w] << 8) | img[2 * w + 1];
    uint16_t in[3] = {0xffff, 0xffff, 0xffff};
    dut->dsw = 0x7ffd;
    dut->in0 = in[0]; dut->in1 = in[1]; dut->in2 = in[2];
    dut->init = 1; dut->rst = 1;
    auto tick = [&]() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); clocks++; };
    for (int i = 0; i < 16; i++) tick();
    dut->init = 0;
    while (!dut->ready) tick();
    for (int i = 0; i < 64; i++) tick();
    dut->rst = 0;

    int sram_wait = 0;
    long frame = 0;
    bool vb_q = true;
    std::vector<uint8_t> pic(400 * 254 * 3);
    int px = 0; long line_px = 0; bool capturing = false;
    std::vector<int16_t> samples;
    uint32_t sdiv = 0;
    auto t0 = std::chrono::steady_clock::now();
    uint64_t busy = 0, busy_max = 0;
    FILE *log = fopen((outdir + "/machine.log").c_str(), "w");

    while (frame < frames) {
        tick();
        // the SRAM: a byte three clocks after the request
        if (dut->srom_req && !dut->srom_ack) {
            if (++sram_wait == 3) { dut->srom_q = img[0xa00000 + dut->srom_addr]; dut->srom_ack = 1; sram_wait = 0; }
        } else { dut->srom_ack = 0; sram_wait = 0; }
        if (dut->dbg_blit_busy) busy++;
        // audio at 48 kHz
        if (!wav.empty() && ++sdiv == 2000) { sdiv = 0; samples.push_back(dut->snd); }
        // picture: the frame's visible pixels as they are emitted
        if (dut->pix_ce) {
            // de is registered on the dot enable: sample the dot after
            if (dut->de) {
                if (capturing && px < 400 * 254) {
                    pic[3 * px] = dut->rgb >> 16; pic[3 * px + 1] = dut->rgb >> 8; pic[3 * px + 2] = dut->rgb;
                    px++;
                }
            }
        }
        bool vb = dut->vblank;
        if (!vb && vb_q) { capturing = true; px = 0; }
        if (vb && !vb_q) {
            frame++;
            if (busy > busy_max) busy_max = busy;
            if (snaps.count(frame)) {
                char name[512]; snprintf(name, sizeof name, "%s/frame_%05ld.rgb", outdir.c_str(), frame);
                FILE *f = fopen(name, "wb"); fwrite(pic.data(), 1, pic.size(), f); fclose(f);
            }
            capturing = false;
            fprintf(log, "frame %ld pc %08x blit %llu late %u skip %u snd_stalls %u snd_pc %04x unimpl %d\n",
                    frame, dut->dbg_pc, (unsigned long long)busy, dut->dbg_late, dut->dbg_skipmode,
                    dut->dbg_snd_stalls, dut->dbg_snd_pc, dut->dbg_unimpl);
            fflush(log);
            busy = 0;
            // inputs for the frame that starts now (MAME applies them in frame_done)
            for (auto &e : script[frame]) {
                int which; int b = bit_of(e.port, e.field, which);
                if (b < 0) continue;
                if (e.v) in[which] &= ~(1u << b); else in[which] |= (1u << b);
            }
            dut->in0 = in[0]; dut->in1 = in[1]; dut->in2 = in[2];
            if (frame % 50 == 0) {
                double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
                printf("frame %ld  %.2f s/frame  pc %08x  unimpl %d  late %u\n", frame, s / frame, dut->dbg_pc, dut->dbg_unimpl, dut->dbg_late);
                fflush(stdout);
            }
        }
        vb_q = vb;
    }
    fclose(log);
    if (!wav.empty()) {
        FILE *f = fopen(wav.c_str(), "wb");
        uint32_t n = samples.size() * 2, sr = 48000, br = 96000;
        fwrite("RIFF", 1, 4, f); uint32_t x = 36 + n; fwrite(&x, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
        x = 16; fwrite(&x, 4, 1, f); uint16_t h = 1; fwrite(&h, 2, 1, f); fwrite(&h, 2, 1, f);
        fwrite(&sr, 4, 1, f); fwrite(&br, 4, 1, f); h = 2; fwrite(&h, 2, 1, f); h = 16; fwrite(&h, 2, 1, f);
        fwrite("data", 1, 4, f); fwrite(&n, 4, 1, f); fwrite(samples.data(), 2, samples.size(), f); fclose(f);
    }
    printf("%ld frames, %llu clocks, worst blitter frame %llu clocks, unimpl %d, late lines %u, sound stalls %u\n",
           frame, (unsigned long long)clocks, (unsigned long long)busy_max, dut->dbg_unimpl, dut->dbg_late, dut->dbg_snd_stalls);
    delete dut;
    return 0;
}
