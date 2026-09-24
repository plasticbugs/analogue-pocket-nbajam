//------------------------------------------------------------------------------
// The Pocket's memories behind the core's ports (docs/core-design.md 2-4).
//
//   SDRAM   graphics ROM     8 MB  word 0x000000   blitter bursts, CPU words
//           34010 program    1 MB  word 0x400000   CPU words
//           OKI samples      1 MB  word 0x480000   bytes for jt6295
//           VRAM             1 MB  word 0x800000   bursts (scan-out, SRT,
//                                                   blitter), CPU words
//           work RAM       512 KB  word 0xC00000   CPU words
//   SRAM    6809 program   128 KB  word 0x00000    bytes for the sound CPU
//
// The image arrives from the Pocket a byte at a time in the order nbajam.mra
// builds it: bytes 0-0x9fffff are the SDRAM's first 10 MB exactly (first
// byte of each pair high), 0xa00000-0xa1ffff the 6809's program, which goes
// to the SRAM.  The loader cannot be told to wait -- a byte every eight
// clocks whatever the memories are doing -- so every word goes through a
// FIFO deep enough to ride out a refresh or a burst (METHODOLOGY 5.16), and
// each byte is taken once, on the strobe's rising edge (5.8).
//
// SDRAM clients (sdram_ctrl's round robin): 0 the download, 1 the CPU, 2 the
// OKI.  The burst port is the core's own (it arbitrates its three users
// itself, owner latched at grant).  Bursts run one word a clock (FAST_BURST).
//------------------------------------------------------------------------------
`default_nettype none

module nbajam_mem (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz, phase shifted, drives the pin
    input  logic        init,           // hold to (re)initialise the SDRAM
    output logic        ready,

    input  logic        rd_late,        // SDRAM diagnostics, from the Pocket menu
    input  logic        burst_slow,
    input  logic        sram_slow,
    input  logic        sram_slow_wr,

    // the ROM image arriving from the Pocket
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    input  logic        dl_active,

    // ---------------- the core's ports (rtl/nbajam_core.sv)
    input  logic        sd_req,  input  logic        sd_we,
    input  logic [24:1] sd_addr, input  logic [15:0] sd_wdata, input logic [1:0] sd_be,
    output logic        sd_ack,  output logic [15:0] sd_q,

    input  logic [24:1] b_addr,  input  logic  [9:0] b_len,
    input  logic        b_req,   input  logic        b_we,
    input  logic [15:0] b_wdata, input  logic  [1:0] b_be,
    output logic        b_wr,    output logic  [9:0] b_idx,
    output logic [15:0] b_data,  output logic        b_done,
    output logic  [9:0] b_widx,  output logic  [9:0] b_wpre,

    input  logic        oki_req, input  logic [19:0] oki_addr,
    output logic        oki_ack, output logic  [7:0] oki_q,

    input  logic        srom_req, input logic [16:0] srom_addr,
    output logic        srom_ack, output logic [7:0] srom_q,

    // ---------------- core_top's SRAM self-test, before the core runs
    input  logic        tst_active,
    input  logic        tst_req, input  logic        tst_we,
    input  logic [16:0] tst_addr, input logic [15:0] tst_din,
    output logic        tst_ack, output logic [15:0] tst_q,

    // SDRAM pins
    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic        SDRAM_DQML, SDRAM_DQMH,
    output logic  [1:0] SDRAM_BA,
    output logic        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
    output logic        SDRAM_CKE, SDRAM_CLK,

    // SRAM pins
    output logic [16:0] sram_a,
    inout  wire  [15:0] sram_dq,
    output logic        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n
);
    localparam logic [24:1] OKI_W  = 24'h480000;
    localparam logic [24:0] SROM_B = 25'h0a00000;     // where the 6809 program starts in the image

    // ------------------------------------------------------------ download
    // {to SRAM, word address [24:1], data}
    localparam int DLQ = 64;
    logic [40:0] dlq [DLQ];
    logic  [6:0] dlq_wp, dlq_rp;
    logic  [7:0] dl_hi;
    logic        dl_we_d;
    wire         dlq_empty = (dlq_wp == dlq_rp);
    wire  [40:0] dlq_head  = dlq[dlq_rp[5:0]];
    wire         nb        = dl_we && !dl_we_d;       // one byte, once
    wire         dl_sram   = (dl_addr >= SROM_B);
    wire  [24:1] dl_target = dl_sram ? 24'((dl_addr - SROM_B) >> 1) : dl_addr[24:1];
    wire         head_sram = dlq_head[40];
    logic        pop_sd, pop_sr;
    // the 6809's 128 KB is 64K words: sram_port's 16-bit address is enough

    always_ff @(posedge clk) begin
        dl_we_d <= dl_we;
        if (init) begin
            dlq_wp <= '0;
            dlq_rp <= '0;
        end else begin
            if (nb) begin
                if (!dl_addr[0]) dl_hi <= dl_data;
                else begin
                    dlq[dlq_wp[5:0]] <= {dl_sram, dl_target, dl_hi, dl_data};
                    dlq_wp <= dlq_wp + 7'd1;
                end
            end
            if (pop_sd || pop_sr) dlq_rp <= dlq_rp + 7'd1;
        end
    end

    // ---------------------------------------------------- SDRAM clients
    localparam int NCLI = 3;
    logic [24:1] c_addr  [NCLI];
    logic        c_req   [NCLI];
    logic        c_we    [NCLI];
    logic [15:0] c_wdata [NCLI];
    logic  [1:0] c_be    [NCLI];
    logic        c_ack   [NCLI];
    logic [15:0] rdata;

    // 0: the download (SDRAM words only)
    assign c_addr[0]  = dlq_head[39:16];
    assign c_req[0]   = !dlq_empty && !head_sram;
    assign c_we[0]    = 1'b1;
    assign c_wdata[0] = dlq_head[15:0];
    assign c_be[0]    = 2'b11;
    assign pop_sd     = c_ack[0];

    // 1: the CPU.  The ack is registered, and the request is masked on the
    // clock it goes out, so a client that holds req and changes the address
    // after its ack makes a fresh request, never a repeat of the old one.
    logic sd_ack_q;
    assign c_addr[1]  = sd_addr;
    assign c_req[1]   = sd_req && !sd_ack_q;
    assign c_we[1]    = sd_we;
    assign c_wdata[1] = sd_wdata;
    assign c_be[1]    = sd_be;
    always_ff @(posedge clk) begin
        sd_ack_q <= c_ack[1];
        sd_ack   <= c_ack[1];
        if (c_ack[1]) sd_q <= rdata;
    end

    // 2: the OKI, bytes two to a word, first byte high
    logic oki_ack_q, oki_lo;
    assign c_addr[2]  = OKI_W | {5'd0, oki_addr[19:1]};
    assign c_req[2]   = oki_req && !oki_ack_q;
    assign c_we[2]    = 1'b0;
    assign c_wdata[2] = 16'd0;
    assign c_be[2]    = 2'b11;
    always_ff @(posedge clk) begin
        oki_ack_q <= c_ack[2];
        oki_ack   <= c_ack[2];
        if (c_req[2]) oki_lo <= oki_addr[0];
        if (c_ack[2]) oki_q <= oki_lo ? rdata[7:0] : rdata[15:8];
    end

    sdram_ctrl #(.NCLI(NCLI), .FAST_BURST(1'b1)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init),
        .rd_late(rd_late), .burst_slow(burst_slow), .ready(ready),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata),
        .c_be(c_be), .c_ack(c_ack), .rdata(rdata),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_abort(1'b0),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(b_we), .b_wdata(b_wdata), .b_be(b_be), .b_widx(b_widx), .b_wpre(b_wpre)
    );

    // -------------------------------------------------------------- SRAM
    // Three users, never at once: the download (the core is in reset), the
    // self-test (after the download, before the core runs), and the sound
    // CPU.  Who is using the port is decided by the phase, not by who asks;
    // the ack goes back to that one alone.
    typedef enum logic [1:0] { R_DL, R_TST, R_CORE } sown_t;
    sown_t sown;
    assign sown = dl_active ? R_DL : tst_active ? R_TST : R_CORE;
    logic        s_req, s_we, s_ack;
    logic [16:0] s_addr;
    logic [15:0] s_wdata, s_q;
    logic [1:0]  s_be;
    logic        srom_lo;

    always_comb begin
        unique case (sown)
            R_DL: begin
                s_req = !dlq_empty && head_sram; s_we = 1'b1;
                s_addr = dlq_head[32:16]; s_wdata = dlq_head[15:0]; s_be = 2'b11;
            end
            R_TST: begin
                s_req = tst_req; s_we = tst_we; s_addr = tst_addr; s_wdata = tst_din; s_be = 2'b11;
            end
            default: begin
                s_req = srom_req && !srom_ack; s_we = 1'b0;
                s_addr = {1'b0, srom_addr[16:1]}; s_wdata = 16'd0; s_be = 2'b11;
            end
        endcase
    end
    // A download word leaves the FIFO on the clock the port acknowledges it:
    // sram_port only acks a request still standing, and ignores one on the
    // clock of its ack, so on the next clock the head is already the next
    // word.  (Registered, the pop came a clock late: the port took the old
    // word again, and the FIFO then skipped a word.)
    assign pop_sr = (sown == R_DL) && s_ack;
    assign tst_ack = (sown == R_TST) && s_ack;
    assign tst_q   = s_q;
    always_ff @(posedge clk) begin
        srom_ack <= 1'b0;
        if (s_req && sown == R_CORE) srom_lo <= srom_addr[0];
        if (sown == R_CORE && s_ack) begin
            srom_ack <= 1'b1;
            srom_q   <= srom_lo ? s_q[7:0] : s_q[15:8];
        end
    end

    sram_port u_sram (
        .clk(clk), .reset(init), .slow(sram_slow), .slow_wr(sram_slow_wr),
        .req(s_req), .we(s_we), .addr(s_addr[15:0]), .be(s_be), .wdata(s_wdata),
        .ack(s_ack), .q(s_q),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );
endmodule

`default_nettype wire
