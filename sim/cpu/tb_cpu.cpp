// (From Smash TV's sim/tb_cpu.cpp: NBA Jam's program is 1 MB at FF800000,
// and a shift-register WRITE -- NBA Jam's page clear -- is acknowledged with
// nothing to check, as MAME performs it with a callback and no bus access.)
//
// Hold rtl/tms34010.sv to MAME, one instruction and one bus transaction at a
// time (METHODOLOGY section 4).
//
//   obj_cpu/Vtb_cpu_top <trace-dir> <image.rom> [-n instructions] [-v]
//
// The trace directory is what tools/cpu_trace.sh wrote:
//
//   trace_bus.bin   every transaction MAME's TMS34010 made.  It is both the
//                   check and the stimulus: each transaction the RTL makes
//                   must be the next one in the file, and each read is
//                   answered with the data MAME's CPU was given -- so the RTL
//                   sees the same vertical counter, the same blitter busy
//                   bit, the same inputs, whatever the program polls.
//   trace_reg.txt   the register file before every instruction.  Compared at
//                   every instruction start, so a wrong flag is caught at the
//                   instruction that set it and not at the branch, thousands
//                   of instructions later, that finally uses it.
//
// Interrupts are asynchronous in MAME and have to be replayed: when the
// register trace shows the next instruction is the first of a handler, the
// bench raises that interrupt one instruction earlier, and the RTL must then
// enter it at the same boundary MAME did.
//
// The bus trace starts after reset -- MAME reads the reset vector inside
// device_reset(), before a script can install a tap -- so the vector read is
// answered from the ROM image and the comparison starts at the first fetch.
#include "Vtb_cpu_top.h"
#include "Vtb_cpu_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <deque>
#include <map>
#include <algorithm>
#include <string>
#include <vector>

#pragma pack(push, 1)
struct Tx { uint32_t idx, addr; uint16_t data, mask; uint8_t write, region; uint16_t pad; };
#pragma pack(pop)

struct Insn { uint32_t pc; uint32_t r[32]; char text[48]; uint64_t cyc; bool has_cyc; };   // r: ST A0-14 B0-14 SP

static Vtb_cpu_top *dut;
static long cycles = 0;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; }

static const char *RN[32] = {"ST","A0","A1","A2","A3","A4","A5","A6","A7","A8","A9","A10",
    "A11","A12","A13","A14","B0","B1","B2","B3","B4","B5","B6","B7","B8","B9","B10","B11",
    "B12","B13","B14","SP"};

static uint32_t rtl_reg(int i) {
    auto *r = dut->rootp;
    if (i == 0)  return r->tb_cpu_top__DOT__u_cpu__DOT__st;
    if (i == 31) return r->tb_cpu_top__DOT__u_cpu__DOT__sp;
    if (i <= 15) return r->tb_cpu_top__DOT__u_cpu__DOT__ra[i - 1];
    return r->tb_cpu_top__DOT__u_cpu__DOT__rb[i - 16];
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<std::string> pos;
    long limit = 0; bool verbose = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-n" && i + 1 < argc) limit = atol(argv[++i]);
        else if (a == "-v") verbose = true;
        else if (a[0] != '+' && a[0] != '-') pos.push_back(a);
    }
    if (pos.size() < 2) { fprintf(stderr, "usage: %s <trace-dir> <image.rom> [-n N]\n", argv[0]); return 2; }

    // ---- the program ROM, for the reset vector only
    // the image holds the program at 0x800000 as SDRAM words, first byte high
    std::vector<uint8_t> rom(0x100000);
    { FILE *f = fopen(pos[1].c_str(), "rb");
      if (!f || fseek(f, 0x800000, SEEK_SET) || fread(rom.data(), 1, rom.size(), f) != rom.size()) { fprintf(stderr, "cannot read %s\n", pos[1].c_str()); return 2; }
      fclose(f); }
    auto rom_word = [&](uint32_t bitaddr) -> uint16_t {
        uint32_t w = ((bitaddr - 0xff800000u) >> 4) & 0x7ffff;
        return uint16_t((rom[2 * w] << 8) | rom[2 * w + 1]);
    };

    // ---- both traces are read as they are needed, never whole: they may be
    // files, or named pipes with MAME still running on the other end
    // (sim/run_cpu.sh -live), which is what lets this run for thousands of
    // frames without hundreds of gigabytes of trace.
    FILE *fbus = fopen((pos[0] + "/trace_bus.bin").c_str(), "rb");
    FILE *freg = fopen((pos[0] + "/trace_reg.txt").c_str(), "r");
    if (!fbus || !freg) { fprintf(stderr, "no traces in %s\n", pos[0].c_str()); return 2; }
    setvbuf(fbus, nullptr, _IOFBF, 1 << 20);
    setvbuf(freg, nullptr, _IOFBF, 1 << 20);

    auto next_tx = [&](Tx &t) { return fread(&t, sizeof(t), 1, fbus) == 1; };
    auto next_insn = [&](Insn &out) {
        char line[1024]; bool have = false;
        while (fgets(line, sizeof(line), freg)) {
            if (line[0] == '=') {
                char *p = line + 1;
                for (int i = 0; i < 32; i++) out.r[i] = uint32_t(strtoul(p, &p, 16));
                // an optional 33rd column: MAME's running cycle count (CYCLES=1)
                char *q; out.cyc = strtoull(p, &q, 16); out.has_cyc = (q != p);
                have = true;
            } else if (have && strlen(line) > 9 && line[8] == ':') {
                out.pc = uint32_t(strtoul(line, nullptr, 16));
                strncpy(out.text, line + 10, sizeof(out.text) - 1);
                out.text[sizeof(out.text) - 1] = 0;
                char *nl = strchr(out.text, '\n'); if (nl) *nl = 0;
                return true;
            }
        }
        return false;
    };
    struct Cyc { long n = 0, mame = 0, rtl = 0, bad = 0; std::string ex; long ex_m = 0, ex_r = 0; };
    std::map<std::string, Cyc> cyc_by;
    bool prev_has = false; uint64_t prev_mcyc = 0; uint32_t prev_rcyc = 0;
    std::string prev_key, prev_text; long tot_m = 0, tot_r = 0;
    // one instruction of look-ahead, to see an interrupt coming
    Insn cur_i, nxt_i;
    bool have_cur = next_insn(cur_i), have_nxt = have_cur && next_insn(nxt_i);
    Tx cur_t; bool have_t = next_tx(cur_t);

    // ---- interrupt entry points: the handler addresses, from the vectors
    auto rom_long = [&](uint32_t a) { return uint32_t(rom_word(a)) | (uint32_t(rom_word(a + 16)) << 16); };
    const uint32_t h_di = rom_long(0xfffffea0) & ~0xfu, h_x1 = rom_long(0xffffffc0) & ~0xfu,
                   h_x2 = rom_long(0xffffffa0) & ~0xfu;
    printf("handlers: display %08x, external-1 %08x, external-2 %08x\n", h_di, h_x1, h_x2);

    dut = new Vtb_cpu_top;
    dut->rst = 1; dut->bus_ack = 0; dut->int1 = dut->int2 = dut->dpyint = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 0;
    tick();     // the CPU registers its reset: let that clear before anything is poked below

    // ---- a warm start: the traces begin at some frame, not at reset, so the
    // RTL is given MAME's registers as of the first traced instruction and
    // the I/O registers tools/bus_trace.lua wrote down at the same instant
    bool warm = false;
    { FILE *f = fopen((pos[0] + "/ioregs.txt").c_str(), "r");
      if (f && have_cur) {
          unsigned io[32] = {0}; for (int i = 0; i < 32; i++) if (fscanf(f, "%x", &io[i]) != 1) break;
          fclose(f);
          auto *r = dut->rootp;
          r->tb_cpu_top__DOT__u_cpu__DOT__st = cur_i.r[0];
          for (int i = 0; i < 15; i++) {
              r->tb_cpu_top__DOT__u_cpu__DOT__ra[i] = cur_i.r[1 + i];
              r->tb_cpu_top__DOT__u_cpu__DOT__rb[i] = cur_i.r[16 + i];
          }
          r->tb_cpu_top__DOT__u_cpu__DOT__sp = cur_i.r[31];
          r->tb_cpu_top__DOT__u_cpu__DOT__pc = cur_i.pc;
          r->tb_cpu_top__DOT__u_cpu__DOT__io_control = io[0x0b];
          r->tb_cpu_top__DOT__u_cpu__DOT__io_intenb  = io[0x11];
          r->tb_cpu_top__DOT__u_cpu__DOT__io_intpend = io[0x12] & 0x0c00;
          r->tb_cpu_top__DOT__u_cpu__DOT__io_convsp  = io[0x13];
          r->tb_cpu_top__DOT__u_cpu__DOT__io_convdp  = io[0x14];
          r->tb_cpu_top__DOT__u_cpu__DOT__io_psize   = io[0x15];
          r->tb_cpu_top__DOT__u_cpu__DOT__io_pmask   = io[0x16];
          r->tb_cpu_top__DOT__u_cpu__DOT__state = 3;          // S_FETCH
          warm = true;
          printf("warm start at %08x\n", cur_i.pc);
          // The frame notifier can fire while an interrupt is being entered,
          // so the bus trace may begin with the entry's stack writes while the
          // register trace begins inside the handler: line them up on the
          // first instruction's opcode fetch.
          long skipped = 0;
          while (have_t && !(cur_t.addr == cur_i.pc && !cur_t.write)) { have_t = next_tx(cur_t); skipped++; }
          if (skipped) printf("skipped %ld bus transactions to the first opcode fetch\n", skipped);
      } else if (f) fclose(f); }

    size_t ti = 0, ii = 0;
    long irqs = 0, reexec = 0, srts = 0;
    uint32_t gfx_pc = 0;
    std::deque<std::string> recent;
    bool pending_ack = false;
    int  fail = 0;

    auto context = [&]() {
        printf("  the last instructions MAME executed:\n");
        for (auto &s : recent) printf("    %s\n", s.c_str());
    };

    while (!fail) {
        tick();
        if (cycles > 4000000000L) { printf("FAIL  ran away\n"); fail = 1; break; }
        if (dut->unimpl) {
            printf("STOP  the RTL met an instruction it does not implement, at instruction %zu\n", ii);
            context(); fail = 2; break;
        }

        // ---- an instruction is starting: the registers must be MAME's
        if (dut->insn_start) {
            if (!have_cur || (limit && long(ii) >= limit)) break;
            const Insn m = cur_i;
            // ---- cycles: what each side charged for the instruction that
            // has just finished (and any interrupt entry that followed it)
            {
                uint32_t rc = dut->rootp->tb_cpu_top__DOT__u_cpu__DOT__cyc_total;
                if (prev_has && m.has_cyc) {
                    long md = long(m.cyc - prev_mcyc), rd = long(rc - prev_rcyc);
                    auto &c = cyc_by[prev_key];
                    c.n++; c.mame += md; c.rtl += rd;
                    if (md != rd) { if (!c.bad) { c.ex = prev_text; c.ex_m = md; c.ex_r = rd; } c.bad++; }
                    tot_m += md; tot_r += rd;
                }
                prev_has = m.has_cyc; prev_mcyc = m.cyc; prev_rcyc = rc;
                prev_text = m.text;
                // the key: the mnemonic and the shape of its operands
                std::string k;
                for (const char *c = m.text; *c; c++) {
                    if (isxdigit((unsigned char)*c) && (c == m.text || !isalpha((unsigned char)c[-1]) || k.empty() || k.back() == '#')) {
                        if (k.empty() || k.back() != '#') k += '#';
                    } else if (*c == 'h' && !k.empty() && k.back() == '#') {
                    } else k += *c;
                }
                prev_key = k;
            }
            bool bad = (dut->dbg_pc != m.pc);
            for (int i = 0; i < 32 && !bad; i++) if (rtl_reg(i) != m.r[i]) bad = true;
            if (bad) {
                printf("FAIL  at instruction %zu the RTL's state is not MAME's\n", ii);
                if (dut->dbg_pc != m.pc) printf("    PC   rtl %08x  MAME %08x\n", dut->dbg_pc, m.pc);
                for (int i = 0; i < 32; i++)
                    if (rtl_reg(i) != m.r[i])
                        printf("    %-4s rtl %08x  MAME %08x\n", RN[i], rtl_reg(i), m.r[i]);
                context(); fail = 1; break;
            }
            char b[96]; snprintf(b, sizeof(b), "%8zu  %08X: %s", ii, m.pc, m.text);
            recent.push_back(b); if (recent.size() > 12) recent.pop_front();

            // is MAME about to enter an interrupt after this instruction?
            if (have_nxt) {
                uint32_t np = nxt_i.pc;
                bool is_h = (np == h_di || np == h_x1 || np == h_x2);
                // a handler entered by an interrupt: ST was reset to 0x10
                if (is_h && nxt_i.r[0] == 0x00000010 && strncmp(m.text, "TRAP", 4) != 0) {
                    if (np == h_di) dut->dpyint = 1;
                    else if (np == h_x1) dut->int1 = 1;
                    else dut->int2 = 1;
                    irqs++;
                }
            }
            ii++;
            // MAME runs a PIXBLT, FILL or LINE to completion the first time
            // and then executes the same instruction again, as many times as
            // its timeslice needs, only to burn the cycles.  Those entries --
            // same PC, straight after -- are the emulator's bookkeeping.
            bool gfx = !strncmp(m.text, "PIXBLT", 6) || !strncmp(m.text, "FILL", 4)
                    || !strncmp(m.text, "LINE", 4);
            if (gfx) gfx_pc = m.pc;
            cur_i = nxt_i; have_cur = have_nxt;
            if (have_nxt) have_nxt = next_insn(nxt_i);
            while (gfx && have_cur && cur_i.pc == m.pc) {
                reexec++;
                cur_i = nxt_i; have_cur = have_nxt;
                if (have_nxt) have_nxt = next_insn(nxt_i);
            }
            if ((ii % 5000000) == 0) { printf("  ... %zu instructions\n", ii); fflush(stdout); }
        } else {
            dut->dpyint = 0;
        }
        if (dut->irq_taken) { dut->int1 = 0; dut->int2 = 0; }

        // ---- the bus
        if (pending_ack) { dut->bus_ack = 0; pending_ack = false; continue; }
        if (dut->bus_req && !dut->bus_ack) {
            uint32_t a = dut->bus_addr;
            if (dut->bus_srt && dut->bus_we) {
                // a shift-register write: nothing on MAME's bus to compare
                srts++;
            } else if (dut->bus_srt) {
                // A shift-register transfer.  MAME does it with a callback
                // and no bus access, so there is nothing in the bus trace to
                // check or to answer from; what it left in the destination
                // register is in the next instruction's state, which by now
                // is cur_i.  The destination is the last operand.
                const char *c = strrchr(recent.back().c_str(), ',');
                int reg = -1;
                if (c && c[1] == 'A') reg = 1 + atoi(c + 2);
                else if (c && c[1] == 'B') reg = 16 + atoi(c + 2);
                else if (c && c[1] == 'S') reg = 31;
                dut->bus_rdata = (reg >= 0) ? uint16_t(cur_i.r[reg]) : 0;
                srts++;
            } else if (ii == 0 && !warm) {       // the reset vector, before the trace begins
                dut->bus_rdata = rom_word(a);
            } else {
                // ...and each of those re-executions fetched the opcode again
                while (have_t && gfx_pc && !cur_t.write && cur_t.addr == gfx_pc
                       && !(a == gfx_pc && !dut->bus_we))
                    have_t = next_tx(cur_t);
                if (!have_t) break;
                const Tx t = cur_t;
                bool ok = (t.addr == a) && (bool(t.write) == bool(dut->bus_we))
                       && (!dut->bus_we || t.data == dut->bus_wdata);
                if (!ok) {
                    printf("FAIL  bus transaction %zu, during instruction %zu\n", ti, ii - 1);
                    printf("    rtl  %s %08x %04x\n", dut->bus_we ? "W" : "R", a,
                           dut->bus_we ? dut->bus_wdata : 0);
                    printf("    MAME %s %08x %04x\n", t.write ? "W" : "R", t.addr, t.data);
                    context(); fail = 1; break;
                }
                dut->bus_rdata = t.data;
                ti++;
                have_t = next_tx(cur_t);
            }
            dut->bus_ack = 1; pending_ack = true;
        }
    }

    printf("%zu instructions and %zu transactions matched MAME; %ld interrupts replayed, "
           "%ld graphics re-executions stepped over, %ld shift-register transfers\n",
           ii, ti, irqs, reexec, srts);
    if (tot_m) {
        printf("\ncycles charged: MAME %ld, RTL %ld (%+.3f%%)\n", tot_m, tot_r, 100.0 * (tot_r - tot_m) / tot_m);
        std::vector<std::pair<std::string, Cyc>> v(cyc_by.begin(), cyc_by.end());
        std::sort(v.begin(), v.end(), [](auto &a, auto &b) { return labs(a.second.rtl - a.second.mame) > labs(b.second.rtl - b.second.mame); });
        printf("%-34s %9s %11s %11s %9s   first mismatch\n", "form", "count", "MAME", "RTL", "differ");
        int shown = 0;
        for (auto &e : v) {
            if (!e.second.bad || shown++ >= 40) continue;
            printf("%-34s %9ld %11ld %11ld %9ld   %s: MAME %ld, RTL %ld\n", e.first.c_str(), e.second.n,
                   e.second.mame, e.second.rtl, e.second.bad, e.second.ex.c_str(), e.second.ex_m, e.second.ex_r);
        }
        if (!shown) printf("every instruction was charged what MAME charges\n");
    }
    delete dut;
    if (fail == 1) return 1;
    if (fail == 2) return 3;
    printf("PASS  every register and every transaction is MAME's\n");
    return 0;
}
