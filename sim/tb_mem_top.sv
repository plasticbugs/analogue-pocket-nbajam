// Bench wrapper for target/pocket/nbajam_mem.sv: the Pocket memory subsystem
// with behavioural chips behind the pins.  sim/tb_mem.cpp pushes an image in
// through the download port at the APF loader's rate and reads every region
// back through the core's ports (METHODOLOGY section 5.16).
`default_nettype none
module tb_mem_top (
    input  logic        clk,
    input  logic        init,
    output logic        ready,
    input  logic        rd_late, burst_slow,
    input  logic        dl_we, input logic [24:0] dl_addr, input logic [7:0] dl_data,
    input  logic        dl_active,
    input  logic        sd_req, input logic sd_we, input logic [24:1] sd_addr,
    input  logic [15:0] sd_wdata, input logic [1:0] sd_be,
    output logic        sd_ack, output logic [15:0] sd_q,
    input  logic [24:1] b_addr, input logic [9:0] b_len, input logic b_req,
    output logic        b_wr, output logic [9:0] b_idx, output logic [15:0] b_data, output logic b_done,
    input  logic        oki_req, input logic [19:0] oki_addr,
    output logic        oki_ack, output logic [7:0] oki_q,
    input  logic        srom_req, input logic [16:0] srom_addr,
    output logic        srom_ack, output logic [7:0] srom_q,
    // the power-on self-test, the real module, as core_top runs it
    input  logic        tst_hold,
    output logic        tst_done, output logic [15:0] tst_rd0, tst_rd1
);
    logic        tst_req, tst_we, tst_ack;
    logic [16:0] tst_addr;
    logic [15:0] tst_din, tst_q;
    sram_selftest #(.A0(17'h00000), .A1(17'h08000)) selftest (
        .clk(clk), .hold(tst_hold), .req(tst_req), .we(tst_we), .addr(tst_addr), .d(tst_din),
        .ack(tst_ack), .q(tst_q), .done(tst_done), .rd0(tst_rd0), .rd1(tst_rd1)
    );
    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CKE, SDRAM_CLK;
    wire [16:0] sram_a; wire [15:0] sram_dq;
    wire        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;
    logic [9:0] b_widx, b_wpre;

    nbajam_mem dut (
        .clk(clk), .clk_sdram(clk), .init(init), .ready(ready),
        .rd_late(rd_late), .burst_slow(burst_slow), .sram_slow(1'b0), .sram_slow_wr(1'b0),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_active(dl_active),
        .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_wdata(sd_wdata), .sd_be(sd_be),
        .sd_ack(sd_ack), .sd_q(sd_q),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b00),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done), .b_widx(b_widx), .b_wpre(b_wpre),
        .oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack), .oki_q(oki_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .tst_active(!tst_done), .tst_req(tst_req), .tst_we(tst_we), .tst_addr(tst_addr),
        .tst_din(tst_din), .tst_ack(tst_ack), .tst_q(tst_q),
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
    wire unused = ^{SDRAM_CLK, b_widx, b_wpre};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire
