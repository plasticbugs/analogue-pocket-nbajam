//------------------------------------------------------------------------------
// Simple dual-port block RAM: one write port, one read port, registered read
// data (1-cycle latency). Read-during-write of the same address returns the
// old or new data unpredictably (`no_rw_check`), which every user here
// tolerates; that is what lets Quartus map it onto M10K without bypass logic.
//------------------------------------------------------------------------------
`default_nettype none

module sdpram #(parameter AW = 10, parameter DW = 16) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] q
);
    (* ramstyle = "no_rw_check" *) logic [DW-1:0] mem [0:(1<<AW)-1];

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        q <= mem[raddr];
    end
endmodule
