// Whole-machine bench, through the Pocket's real memory glue: nbajam_core
// against nbajam_mem, sdram_ctrl and sram_port, with behavioural chips beyond
// the pins and the ROM image sent in through the download port at the APF
// loader's rate (METHODOLOGY section 5.16).  sim/tb_system.cpp drives it.
`default_nettype none
module tb_system_top #(parameter bit BURST_FAST = 1'b1) (
    input  logic        clk,
    input  logic        mem_init,
    output logic        mem_ready,
    input  logic        reset,          // the core's
    input  logic        dl_active,
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    input  logic [15:0] in0, in1, in2, dsw,
    output logic [23:0] rgb,
    output logic        de, pix_ce, vblank,
    output logic signed [15:0] snd,
    output logic [31:0] dbg_pc,
    output logic        dbg_unimpl,
    output logic [15:0] dbg_late, dbg_skipmode, dbg_snd_stalls,
    output logic        dbg_blit_busy
);
    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CKE, SDRAM_CLK;
    wire [16:0] sram_a; wire [15:0] sram_dq;
    wire        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;

    logic        sd_req, sd_we, sd_ack; logic [24:1] sd_addr; logic [15:0] sd_wdata, sd_q; logic [1:0] sd_be;
    logic [24:1] b_addr; logic [9:0] b_len, b_idx, b_widx, b_wpre; logic b_req, b_we, b_wr, b_done;
    logic [15:0] b_wdata, b_data; logic [1:0] b_be;
    logic        oki_req, oki_ack; logic [19:0] oki_addr; logic [7:0] oki_q;
    logic        srom_req, srom_ack; logic [16:0] srom_addr; logic [7:0] srom_q;
    logic        hsync, vsync, hblank; logic [15:0] snd_pc; logic [15:0] tst_q; logic tst_ack;

    // the game, as nbajam_mem recognises it from the image it downloads
    logic game_te;
    nbajam_core core (
        .clk(clk), .rst(reset), .pause(1'b0), .pix_sync(1'b0), .te(game_te),
        .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_wdata(sd_wdata), .sd_be(sd_be),
        .sd_ack(sd_ack), .sd_q(sd_q),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_we(b_we), .b_wdata(b_wdata), .b_be(b_be),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done), .b_widx(b_widx), .b_wpre(b_wpre),
        .oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack), .oki_q(oki_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .in0(in0), .in1(in1), .in2(in2), .dsw(dsw),
        .nv_addr(13'd0), .nv_we(1'b0), .nv_wdata(16'd0), .nv_rdata(), .nv_dirty(),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .pix_ce(pix_ce), .de(de), .snd(snd),
        .dbg_pc(dbg_pc), .dbg_unimpl(dbg_unimpl), .dbg_late(dbg_late), .dbg_skipmode(dbg_skipmode),
        .dbg_snd_stalls(dbg_snd_stalls), .dbg_snd_pc(snd_pc), .dbg_blit_busy(dbg_blit_busy)
    );

    nbajam_mem mem (
        .game_te(game_te),
        .clk(clk), .clk_sdram(clk), .init(mem_init), .ready(mem_ready),
        .rd_late(1'b1), .burst_slow(1'b0), .burst_fast(BURST_FAST), .sram_slow(1'b0), .sram_slow_wr(1'b0),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_active(dl_active),
        .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_wdata(sd_wdata), .sd_be(sd_be),
        .sd_ack(sd_ack), .sd_q(sd_q),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_we(b_we), .b_wdata(b_wdata), .b_be(b_be),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done), .b_widx(b_widx), .b_wpre(b_wpre),
        .oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack), .oki_q(oki_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .tst_active(1'b0), .tst_req(1'b0), .tst_we(1'b0), .tst_addr(17'd0), .tst_din(16'd0),
        .tst_ack(tst_ack), .tst_q(tst_q),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    sdram_model #(.AW(24)) chip (
        .clk(clk), .dq(SDRAM_DQ), .a(SDRAM_A), .ba(SDRAM_BA),
        .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH), .cs_n(SDRAM_nCS),
        .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE), .cke(SDRAM_CKE)
    );
    sram_model sram (.clk(clk), .a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n), .we_n(sram_we_n),
                     .ub_n(sram_ub_n), .lb_n(sram_lb_n));
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{SDRAM_CLK, hsync, vsync, hblank, snd_pc, tst_q, tst_ack};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire
