// Bench wrapper for rtl/tms34010.sv.  The CPU and nothing else: sim/tb_cpu.cpp
// is the whole of the rest of the machine, answering every read with what
// MAME's CPU was given and checking every transaction against MAME's.
`default_nettype none
module tb_cpu_top (
    input  logic        clk,
    input  logic        rst,
    output logic        bus_req,
    output logic        bus_we,
    output logic [31:0] bus_addr,       // the full bit address, low nibble 0
    output logic [15:0] bus_wdata,
    output logic        bus_srt,
    input  logic [15:0] bus_rdata,
    input  logic        bus_ack,
    input  logic        int1, int2, dpyint,
    output logic        insn_start,
    output logic        irq_taken,
    output logic [31:0] dbg_pc,
    output logic        unimpl
);
    logic [31:4] a;
    tms34010 #(.IO_READ_FROM_BUS(1)) u_cpu (
        .clk(clk), .rst(rst), .cen(1'b1),
        .bus_req(bus_req), .bus_we(bus_we), .bus_addr(a),
        .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ack(bus_ack), .bus_srt(bus_srt),
        .int1(int1), .int2(int2), .dpyint(dpyint),
        .insn_start(insn_start), .irq_taken(irq_taken), .dbg_pc(dbg_pc), .unimpl(unimpl)
    );
    assign bus_addr = {a, 4'd0};
endmodule
`default_nettype wire
