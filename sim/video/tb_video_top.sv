// Bench wrapper: the scan-out on the real SDRAM controller and a behavioural
// chip.  sim/video/tb_video.cpp preloads VRAM, palette and registers from a
// frozen state and compares the picture with MAME's.
`default_nettype none
module tb_video_top (
    input  logic        clk,
    input  logic        init,
    output logic        ready,
    input  logic        cen_dot,
    input  logic        vreg_we,
    input  logic  [4:0] vreg_a,
    input  logic [15:0] vreg_d,
    input  logic        pal_we,
    input  logic [14:0] pal_a,
    input  logic [15:0] pal_d,
    output logic [23:0] rgb,
    output logic        de, hsync, vsync, hblank, vblank,
    output logic [14:0] pen,
    output logic [15:0] late,
    output logic  [8:0] vline_o
);
    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CKE, SDRAM_CLK;
    logic [24:1] b_addr; logic [9:0] b_len; logic b_req, b_wr, b_done;
    logic [9:0]  b_idx; logic [15:0] b_data;
    logic [15:0] vreg_q, pal_q; logic env, dpyint; logic [9:0] hdot_o;

    tunit_video dut (
        .clk(clk), .rst(init), .cen_dot(cen_dot),
        .vreg_we(vreg_we), .vreg_a(vreg_a), .vreg_d(vreg_d), .vreg_q(vreg_q), .env(env),
        .pal_we(pal_we), .pal_a(pal_a), .pal_d(pal_d), .pal_be(2'b11), .pal_q(pal_q),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
        .pen(pen), .dpyint(dpyint), .late(late), .hdot_o(hdot_o), .vline_o(vline_o)
    );

    logic [24:1] c_addr [1]; logic c_req [1], c_we [1], c_ack [1];
    logic [15:0] c_wdata [1], rdata; logic [1:0] c_be [1];
    assign c_addr[0] = '0; assign c_req[0] = 1'b0; assign c_we[0] = 1'b0;
    assign c_wdata[0] = '0; assign c_be[0] = 2'b11;
    logic [9:0] b_widx, b_wpre;

    sdram_ctrl #(.NCLI(1), .FAST_BURST(1'b1)) u_sdram (
        .clk(clk), .clk_pin(clk), .init(init),
        .rd_late(1'b1), .burst_slow(1'b0), .burst_fast(1'b1), .burst_fast_wr(1'b1), .ready(ready),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata),
        .c_be(c_be), .c_ack(c_ack), .rdata(rdata),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_abort(1'b0),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b00), .b_widx(b_widx), .b_wpre(b_wpre)
    );
    sdram_model #(.AW(24)) chip (
        .clk(clk), .dq(SDRAM_DQ), .a(SDRAM_A), .ba(SDRAM_BA),
        .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH), .cs_n(SDRAM_nCS),
        .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE), .cke(SDRAM_CKE)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{SDRAM_CLK, rdata, c_ack[0], vreg_q, pal_q, env, dpyint, hdot_o, b_widx, b_wpre};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire
