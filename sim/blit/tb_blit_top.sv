// Bench wrapper: the blitter on the real SDRAM controller and a behavioural
// chip.  sim/blit/tb_blit.cpp preloads the chip, replays a frame's writes and
// compares VRAM with MAME's.
`default_nettype none
`ifndef FAST
`define FAST 1
`endif
module tb_blit_top (
    input  logic        clk,
    input  logic        init,
    output logic        ready,
    input  logic        reg_wr,
    input  logic  [3:0] reg_addr,
    input  logic [15:0] reg_wdata,
    input  logic  [1:0] reg_be,
    output logic [15:0] reg_rdata,
    output logic [15:0] palette,
    output logic        irq,
    output logic        busy,
    output logic [15:0] stat_skipmode
);
    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CKE, SDRAM_CLK;

    logic [24:1] b_addr; logic [9:0] b_len; logic b_req, b_we, b_wr, b_done;
    logic [9:0]  b_idx, b_widx, b_wpre; logic [15:0] b_data, b_wdata; logic [1:0] b_be;

    tunit_dma dut (
        .clk(clk), .reset(init),
        .reg_wr(reg_wr), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_be(reg_be),
        .reg_rdata(reg_rdata), .palette(palette), .irq(irq),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_we(b_we),
        .b_wdata(b_wdata), .b_be(b_be), .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data),
        .b_done(b_done), .b_widx(b_widx), .b_wpre(b_wpre),
        .busy(busy), .stat_skipmode(stat_skipmode)
    );

    logic [24:1] c_addr [1]; logic c_req [1], c_we [1], c_ack [1];
    logic [15:0] c_wdata [1], rdata; logic [1:0] c_be [1];
    assign c_addr[0] = '0; assign c_req[0] = 1'b0; assign c_we[0] = 1'b0;
    assign c_wdata[0] = '0; assign c_be[0] = 2'b11;

    sdram_ctrl #(.NCLI(1), .FAST_BURST(`FAST)) u_sdram (
        .clk(clk), .clk_pin(clk), .init(init),
        .rd_late(1'b1), .burst_slow(1'b0), .ready(ready),
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

    sdram_model #(.AW(24)) chip (
        .clk(clk), .dq(SDRAM_DQ), .a(SDRAM_A), .ba(SDRAM_BA),
        .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH), .cs_n(SDRAM_nCS),
        .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE), .cke(SDRAM_CKE)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{SDRAM_CLK, rdata, c_ack[0]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire
