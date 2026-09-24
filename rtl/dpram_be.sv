//------------------------------------------------------------------------------
// True dual-port block RAM, 16-bit words with byte enables, registered reads
// (1-cycle latency) on both ports. 2D-packed so Quartus infers M10K byte
// enables instead of registers (METHODOLOGY section 5.5).
//------------------------------------------------------------------------------
`default_nettype none

module dpram_be #(parameter AW = 13) (
    input  logic          clk,
    input  logic [AW-1:0] a_addr,
    input  logic          a_we,
    input  logic  [1:0]   a_be,
    input  logic [15:0]   a_wdata,
    output logic [15:0]   a_rdata,
    input  logic [AW-1:0] b_addr,
    input  logic          b_we,
    input  logic  [1:0]   b_be,
    input  logic [15:0]   b_wdata,
    output logic [15:0]   b_rdata
);
    (* ramstyle = "no_rw_check" *) logic [1:0][7:0] mem [0:(1<<AW)-1] /* verilator public_flat_rw */;

    always_ff @(posedge clk) begin
        if (a_we) begin
            if (a_be[0]) mem[a_addr][0] <= a_wdata[7:0];
            if (a_be[1]) mem[a_addr][1] <= a_wdata[15:8];
        end
        a_rdata <= mem[a_addr];
    end
    always_ff @(posedge clk) begin
        if (b_we) begin
            if (b_be[0]) mem[b_addr][0] <= b_wdata[7:0];
            if (b_be[1]) mem[b_addr][1] <= b_wdata[15:8];
        end
        b_rdata <= mem[b_addr];
    end
endmodule
