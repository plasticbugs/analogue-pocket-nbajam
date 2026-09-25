// Bench wrapper: the whole machine on the real SDRAM controller and a
// behavioural chip (preloaded by the bench, so no download), the sound ROM
// answered by sim/machine/tb_machine.cpp as the SRAM would.
`default_nettype none
module tb_machine_top (
    input  logic        te,         // GAME=nbajamte (tb_machine.cpp)
    input  logic        clk,
    input  logic        init,
    output logic        ready,
    input  logic        rst,
    input  logic [15:0] in0, in1, in2, dsw,
    output logic        srom_req,
    output logic [16:0] srom_addr,
    input  logic        srom_ack,
    input  logic  [7:0] srom_q,
    output logic [23:0] rgb,
    output logic        de, hsync, vsync, vblank, pix_ce,
    output logic signed [15:0] snd,
    output logic [31:0] dbg_pc,
    output logic        dbg_unimpl,
    output logic [15:0] dbg_late, dbg_skipmode, dbg_snd_stalls, dbg_snd_pc,
    output logic        dbg_blit_busy
);
    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CKE, SDRAM_CLK;

    logic        sd_req, sd_we, sd_ack; logic [24:1] sd_addr; logic [15:0] sd_wdata, sd_q; logic [1:0] sd_be;
    logic [24:1] b_addr; logic [9:0] b_len, b_idx, b_widx, b_wpre; logic b_req, b_we, b_wr, b_done;
    logic [15:0] b_wdata, b_data; logic [1:0] b_be;
    logic        oki_req, oki_ack; logic [19:0] oki_addr; logic [7:0] oki_q;
    logic        hblank;

    nbajam_core core (
        .clk(clk), .rst(rst), .pause(1'b0), .pix_sync(1'b0), .te(te),
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
        .dbg_snd_stalls(dbg_snd_stalls), .dbg_snd_pc(dbg_snd_pc), .dbg_blit_busy(dbg_blit_busy)
    );

    // two random clients: the CPU and the OKI (a byte of a word)
    logic [24:1] c_addr [2]; logic c_req [2], c_we [2], c_ack [2];
    logic [15:0] c_wdata [2], rdata; logic [1:0] c_be [2];
    logic sd_ack_q, oki_ack_q;
    assign c_addr[0] = sd_addr; assign c_req[0] = sd_req && !sd_ack_q; assign c_we[0] = sd_we;
    assign c_wdata[0] = sd_wdata; assign c_be[0] = sd_be;
    assign c_addr[1] = 24'h480000 | {5'd0, oki_addr[19:1]}; assign c_req[1] = oki_req && !oki_ack_q;
    assign c_we[1] = 1'b0; assign c_wdata[1] = 16'd0; assign c_be[1] = 2'b11;
    logic oki_lo;
    always_ff @(posedge clk) begin
        sd_ack_q <= c_ack[0]; sd_ack <= c_ack[0];
        if (c_ack[0]) sd_q <= rdata;
        oki_ack_q <= c_ack[1]; oki_ack <= c_ack[1];
        if (c_req[1]) oki_lo <= oki_addr[0];
        if (c_ack[1]) oki_q <= oki_lo ? rdata[7:0] : rdata[15:8];
    end

    sdram_ctrl #(.NCLI(2), .FAST_BURST(1'b1)) u_sdram (
        .clk(clk), .clk_pin(clk), .init(init),
        .rd_late(1'b1), .burst_slow(1'b0), .burst_fast(1'b1), .ready(ready),
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
    wire unused = ^{SDRAM_CLK, hblank};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire
