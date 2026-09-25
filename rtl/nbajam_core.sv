//------------------------------------------------------------------------------
// NBA Jam -- the machine, platform-agnostic: the T-unit main board
// (rtl/tunit_main.sv) and the Williams ADPCM sound board (rtl/tunit_sound.sv).
//
// Memory leaves as four ports, which target/pocket/nbajam_mem.sv serves and
// the benches answer (docs/core-design.md sections 2-4):
//
//   sd_*    SDRAM, random access, 16-bit words: the TMS34010
//   b_*     SDRAM, the burst port: scan-out, shift register, blitter
//   oki_*   SDRAM, bytes of the OKI region
//   srom_*  the Pocket's SRAM: bytes of the 6809's program
//------------------------------------------------------------------------------
`default_nettype none

module nbajam_core (
    input  logic        clk,            // 96 MHz
    input  logic        rst,
    input  logic        pause,          // freeze the CPUs and sound, keep the picture
    input  logic        pix_sync,       // see clk_enables.sv
    input  logic        te,             // Tournament Edition (nbajam_mem recognises it as the image loads)

    // ---------------- SDRAM, random access (SDRAM word addresses)
    output logic        sd_req,
    output logic        sd_we,
    output logic [24:1] sd_addr,
    output logic [15:0] sd_wdata,
    output logic  [1:0] sd_be,
    input  logic        sd_ack,
    input  logic [15:0] sd_q,

    // ---------------- SDRAM, the burst port
    output logic [24:1] b_addr,
    output logic  [9:0] b_len,
    output logic        b_req,
    output logic        b_we,
    output logic [15:0] b_wdata,
    output logic  [1:0] b_be,
    input  logic        b_wr,
    input  logic  [9:0] b_idx,
    input  logic [15:0] b_data,
    input  logic        b_done,
    input  logic  [9:0] b_widx,
    input  logic  [9:0] b_wpre,

    // ---------------- OKI samples: byte address in the 1 MB region
    output logic        oki_req,
    output logic [19:0] oki_addr,
    input  logic        oki_ack,
    input  logic  [7:0] oki_q,

    // ---------------- the 6809's program: byte address in u3
    output logic        srom_req,
    output logic [16:0] srom_addr,
    input  logic        srom_ack,
    input  logic  [7:0] srom_q,

    // ---------------- inputs, active low, as the board reads them (hardware.md 3)
    input  logic [15:0] in0, in1, in2, dsw,

    // ---------------- CMOS, for the NVRAM save
    input  logic [12:0] nv_addr,
    input  logic        nv_we,
    input  logic [15:0] nv_wdata,
    output logic [15:0] nv_rdata,
    output logic        nv_dirty,       // toggles on every CMOS write (the save's trigger)

    // ---------------- video, one pixel per pix_ce in the clk domain
    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank,
    output logic        pix_ce, de,

    output logic signed [15:0] snd,

    // ---------------- bring-up
    output logic [31:0] dbg_pc,
    output logic        dbg_unimpl,
    output logic [15:0] dbg_late,
    output logic [15:0] dbg_skipmode,
    output logic [15:0] dbg_snd_stalls,
    output logic [15:0] dbg_snd_pc,
    output logic        dbg_blit_busy
);
    logic cen_cpu, cen_dot;
    clk_enables u_cen (
        .clk(clk), .rst(rst), .pix_sync(pix_sync), .pause(pause),
        .cen_cpu(cen_cpu), .cen_dot(cen_dot)
    );
    assign pix_ce = cen_dot;

    logic [7:0] snd_cmd;
    logic       snd_strobe, snd_reset;

    tunit_main u_main (
        .clk(clk), .rst(rst), .cen_cpu(cen_cpu), .cen_dot(cen_dot), .te(te),
        .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_wdata(sd_wdata),
        .sd_be(sd_be), .sd_ack(sd_ack), .sd_q(sd_q),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_we(b_we),
        .b_wdata(b_wdata), .b_be(b_be), .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data),
        .b_done(b_done), .b_widx(b_widx), .b_wpre(b_wpre),
        .in0(in0), .in1(in1), .in2(in2), .dsw(dsw),
        .snd_cmd(snd_cmd), .snd_strobe(snd_strobe), .snd_reset(snd_reset),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
        .nv_addr(nv_addr), .nv_we(nv_we), .nv_wdata(nv_wdata), .nv_rdata(nv_rdata), .nv_dirty(nv_dirty),
        .dbg_pc(dbg_pc), .dbg_unimpl(dbg_unimpl), .dbg_late(dbg_late),
        .dbg_skipmode(dbg_skipmode), .dbg_blit_busy(dbg_blit_busy)
    );

    tunit_sound u_sound (
        .clk(clk), .rst(rst), .pause(pause), .te(te),
        .cmd(snd_cmd), .cmd_strobe(snd_strobe), .cmd_reset(snd_reset),
        .rom_addr(srom_addr), .rom_req(srom_req), .rom_q(srom_q), .rom_ack(srom_ack),
        .oki_addr(oki_addr), .oki_req(oki_req), .oki_q(oki_q), .oki_ack(oki_ack),
        .snd(snd), .stalls(dbg_snd_stalls), .dbg_pc(dbg_snd_pc)
    );
endmodule

`default_nettype wire
