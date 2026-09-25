// Bench wrapper for rtl/tunit_sound.sv: the sound board alone; the ROMs are
// answered by sim/sound/tb_sound.cpp from the image.
`default_nettype none
module tb_sound_top (
    input  logic        te,         // GAME=nbajamte (tb_sound.cpp)
    input  logic        clk,
    input  logic        rst,
    input  logic  [7:0] cmd,
    input  logic        cmd_strobe,
    input  logic        cmd_reset,
    output logic [16:0] rom_addr,
    output logic        rom_req,
    input  logic  [7:0] rom_q,
    input  logic        rom_ack,
    output logic [19:0] oki_addr,
    output logic        oki_req,
    input  logic  [7:0] oki_q,
    input  logic        oki_ack,
    output logic signed [15:0] snd,
    output logic signed [15:0] ym_l, ym_r, dac_o,
    output logic signed [13:0] oki_o,
    output logic [15:0] stalls, dbg_pc
);
    tunit_sound dut (
        .clk(clk), .rst(rst), .pause(1'b0), .te(te),
        .cmd(cmd), .cmd_strobe(cmd_strobe), .cmd_reset(cmd_reset),
        .rom_addr(rom_addr), .rom_req(rom_req), .rom_q(rom_q), .rom_ack(rom_ack),
        .oki_addr(oki_addr), .oki_req(oki_req), .oki_q(oki_q), .oki_ack(oki_ack),
        .snd(snd), .stalls(stalls), .dbg_pc(dbg_pc)
    );
    assign ym_l  = dut.ym_left;
    assign ym_r  = dut.ym_right;
    assign dac_o = dut.dac_s;
    assign oki_o = dut.oki_snd;
endmodule
`default_nettype wire
