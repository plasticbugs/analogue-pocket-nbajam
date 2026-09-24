//------------------------------------------------------------------------------
// Clock enables from the 96 MHz system clock (docs/core-design.md section 1).
//
//   cen_cpu   the TMS34010's machine cycle, 50 MHz / 8 = 6.25 MHz: 25 pulses
//             in every 384 clocks (an accumulator), so exact on average with
//             one system clock of jitter (10.4 ns on a 160 ns cycle).  The CPU
//             paces itself to MAME's cycle counts on it (rtl/tms34010.sv).
//   cen_dot   the dot clock, 96 / 12 = 8.000 MHz, the board's exactly
//
// The sound board makes its own (rtl/tunit_sound.sv): the 6809's E is an
// exact divide by 48, the YM2151's an accumulator, the OKI's a divide by 96.
//
// `pause` (the Pocket's menu) freezes cen_cpu and nothing else here: the dot
// clock keeps running so the picture stays up (METHODOLOGY 5.5).
//------------------------------------------------------------------------------
`default_nettype none

module clk_enables (
    input  logic clk,
    input  logic rst,
    // one pulse just after each edge of the platform's video clock, which
    // restarts the dot divider so the pixel handed to clk_vid is stable when
    // it is sampled (METHODOLOGY 5.4)
    input  logic pix_sync,
    input  logic pause,
    output logic cen_cpu,
    output logic cen_dot
);
    // the dot divider: sim/lint.sh checks it against the PLL's video clock
    localparam int DOT_DIV = 12;
    logic [8:0] acc;        // 0..383
    logic [3:0] dpix;       // 0..11

    always_ff @(posedge clk) begin
        cen_cpu <= 1'b0;
        if (rst) begin
            acc  <= '0;
            dpix <= '0;
        end else begin
            if (!pause) begin
                if (acc + 9'd25 >= 9'd384) begin acc <= acc + 9'd25 - 9'd384; cen_cpu <= 1'b1; end
                else acc <= acc + 9'd25;
            end
            if (pix_sync)            dpix <= 4'd0;
            else if (dpix == 4'(DOT_DIV - 1)) dpix <= 4'd0;
            else                     dpix <= dpix + 4'd1;
        end
    end
    assign cen_dot = (dpix == 4'd0);
endmodule

`default_nettype wire
