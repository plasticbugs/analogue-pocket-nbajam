//------------------------------------------------------------------------------
// The raster, the display address, the scan-out and the palette
// (docs/hardware.md sections 1, 7.2 and 7.4).  Adapted from Smash TV's
// stv_video.sv, which is proven on the Pocket; what differs is the frame
// buffer (16-bit pixels in SDRAM here, 8-bit in block RAM there), the palette
// (32K entries, pen = pixel & 0x7fff) and no autoerase.
//
// The timing registers belong to the TMS34010: the CPU programs HESYNC..
// VTOTAL, DPYCTL, DPYSTRT, DPYINT, DPYTAP and (NBA Jam does, in its vblank
// handler) DPYADR, and the raster is generated here from them.  They reset
// to the values the game writes, so the raster runs with no CPU (the video
// bench) and stays right after one arrives.
//
// One dot per `cen_dot` = 96 MHz / 12 = 8.000 MHz, the board's dot clock:
// 506 x 289, 400 x 254 visible, 54.707 Hz.
//
// Per line, as MAME's scanline callback does it:
//   1. at dot 0: if this is VSBLNK, load DPYADR from DPYSTRT
//   2. the row this line shows is DPYADR's, before it moves
//   3. at the end of a visible line, move DPYADR on by DUDATE
//
// The row comes from SDRAM, so it is fetched one line AHEAD: at dot 0 of line
// v this module works out the address line v+1 will use -- DPYADR as step 3
// will leave it -- and bursts that 512-pixel row into the other half of a
// double line buffer, with a whole line (6,072 clocks) to do it in.  The
// prediction is exact unless the CPU writes DPYADR or DPYSTRT during a
// visible line; NBA Jam writes them only at line 274 (hardware.md 7.4).  A
// fetch still running when its line starts is counted in `late` (sticky,
// saturating: METHODOLOGY 5.19).
//------------------------------------------------------------------------------
`default_nettype none

module tunit_video #(
    parameter bit          RESET_TO_GAME = 1'b1,
    parameter logic [24:1] VRAM_W        = 24'h800000   // VRAM pixel 0, SDRAM word
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_dot,        // 8 MHz

    // ---------------- the TMS34010's video registers
    input  logic        vreg_we,
    input  logic  [4:0] vreg_a,
    input  logic [15:0] vreg_d,
    output logic [15:0] vreg_q,         // read-back of register vreg_a
    output logic        env,            // DPYCTL.ENV

    // ---------------- palette RAM at 0x01800000 (CPU side)
    input  logic        pal_we,
    input  logic [14:0] pal_a,
    input  logic [15:0] pal_d,
    input  logic  [1:0] pal_be,
    output logic [15:0] pal_q,          // one clock after pal_a

    // ---------------- SDRAM burst port (read only)
    output logic [24:1] b_addr,
    output logic  [9:0] b_len,
    output logic        b_req,
    input  logic        b_wr,
    input  logic  [9:0] b_idx,
    input  logic [15:0] b_data,
    input  logic        b_done,

    // ---------------- picture
    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank, de,
    output logic [14:0] pen,            // the palette index, aligned with rgb

    // ---------------- interrupt, status
    output logic        dpyint,         // one pulse when VCOUNT == DPYINT
    output logic [15:0] late,           // lines whose fetch had not finished
    output logic  [9:0] hdot_o,
    output logic  [8:0] vline_o
);
    localparam int RI_HESYNC = 0, RI_HEBLNK = 1, RI_HSBLNK = 2, RI_HTOTAL = 3,
                   RI_VESYNC = 4, RI_VEBLNK = 5, RI_VSBLNK = 6, RI_VTOTAL = 7,
                   RI_DPYCTL = 8, RI_DPYSTRT = 9, RI_DPYINT = 10, RI_DPYTAP = 27,
                   RI_HCOUNT = 28, RI_VCOUNT = 29, RI_DPYADR = 30;

    // The values NBA Jam writes, measured every 250 frames over 4,750 frames
    // (docs/hardware.md 1).
    logic [15:0] hesync, heblnk, hsblnk, htotal;
    logic [15:0] vesync, veblnk, vsblnk, vtotal;
    logic [15:0] dpyctl, dpystrt, dpyintr, dpytap, dpyadr;
    logic [15:0] hcount_q;
    logic  [9:0] hdot;
    logic  [8:0] vline;

    // ------------------------------------------------------------- raster
    wire [9:0] hlast   = {htotal[8:0], 1'b1};        // (HTOTAL+1)*2 - 1
    wire [9:0] hsy_end = {hesync[8:0], 1'b1};
    wire [9:0] hbl_end = {heblnk[8:0], 1'b0};
    wire [9:0] hbl_sta = {hsblnk[8:0], 1'b0};
    wire [8:0] vlast   = vtotal[8:0];
    wire       eol     = cen_dot && (hdot == hlast);
    wire       sol     = cen_dot && (hdot == 10'd0);
    wire [8:0] vnext   = (vline == vlast) ? 9'd0 : vline + 9'd1;

    always_ff @(posedge clk) begin
        if (rst) begin
            // MAME's screen starts with the beam at the start of vblank, line
            // 274 (frame_done fires at exact multiples of the frame period,
            // measured), so start there too and frame N ends where MAME's does
            hdot <= '0; vline <= 9'd274;
        end else if (cen_dot) begin
            if (hdot == hlast) begin
                hdot  <= '0;
                vline <= vnext;
            end else
                hdot <= hdot + 10'd1;
        end
    end
    // HCOUNT as MAME reads it back (io_register_r): dots halved, plus HEBLNK, wrapped
    wire [16:0] hc_raw = {8'd0, hdot[9:1]} + {1'b0, heblnk};
    always_ff @(posedge clk)
        hcount_q <= (hc_raw > {1'b0, htotal} + 17'd1)
                  ? 16'(hc_raw - {1'b0, htotal} - 17'd1) : 16'(hc_raw);
    assign hdot_o  = hdot;
    assign vline_o = vline;

    function automatic logic vis_line(input logic [8:0] v, input logic [15:0] eb, input logic [15:0] sb);
        return (v >= eb[8:0]) && (v < sb[8:0]);
    endfunction
    wire vis_y = vis_line(vline, veblnk, vsblnk);
    wire vis_x = (hdot >= hbl_end) && (hdot < hbl_sta);

    // ------------------------------------------------- the display address
    // MAME's DUDATE step, as a function so the fetch can predict it
    function automatic logic [15:0] dpy_step(input logic [15:0] a, input logic [15:0] ctl,
                                             input logic [15:0] strt);
        if (a[1:0] == 2'b00)
            return ((a & 16'hfffc) - (ctl & 16'h03fc)) | {14'd0, strt[1:0]};
        else
            return (a & 16'hfffc) | {14'd0, 2'(a[1:0] - 2'd1)};
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            hesync <= RESET_TO_GAME ? 16'h0015 : 16'h0; heblnk <= RESET_TO_GAME ? 16'h0032 : 16'h0;
            hsblnk <= RESET_TO_GAME ? 16'h00fa : 16'h0; htotal <= RESET_TO_GAME ? 16'h00fc : 16'h0;
            vesync <= RESET_TO_GAME ? 16'h0003 : 16'h0; veblnk <= RESET_TO_GAME ? 16'h0014 : 16'h0;
            vsblnk <= RESET_TO_GAME ? 16'h0112 : 16'h0; vtotal <= RESET_TO_GAME ? 16'h0120 : 16'h0;
            dpyctl <= RESET_TO_GAME ? 16'hf010 : 16'h0; dpystrt <= RESET_TO_GAME ? 16'hfffc : 16'h0;
            dpyintr<= RESET_TO_GAME ? 16'h0112 : 16'h0; dpytap  <= 16'h0000;
            dpyadr <= 16'hfffc;
        end else begin
            // 1. at the start of VBLANK, DPYADR <- DPYSTRT
            if (sol && vline == vsblnk[8:0]) dpyadr <= dpystrt;
            // 3. the end of a visible line moves it on
            if (eol && vis_y) dpyadr <= dpy_step(dpyadr, dpyctl, dpystrt);
            // the CPU, last, so its write wins a coincidence
            if (vreg_we) begin
                unique case (vreg_a)
                    5'(RI_HESYNC):  hesync  <= vreg_d;
                    5'(RI_HEBLNK):  heblnk  <= vreg_d;
                    5'(RI_HSBLNK):  hsblnk  <= vreg_d;
                    5'(RI_HTOTAL):  htotal  <= vreg_d;
                    5'(RI_VESYNC):  vesync  <= vreg_d;
                    5'(RI_VEBLNK):  veblnk  <= vreg_d;
                    5'(RI_VSBLNK):  vsblnk  <= vreg_d;
                    5'(RI_VTOTAL):  vtotal  <= vreg_d;
                    5'(RI_DPYCTL):  dpyctl  <= vreg_d;
                    5'(RI_DPYSTRT): dpystrt <= vreg_d;
                    5'(RI_DPYINT):  dpyintr <= vreg_d;
                    5'(RI_DPYTAP):  dpytap  <= vreg_d;
                    5'(RI_DPYADR):  dpyadr  <= vreg_d;
                    default: ;
                endcase
            end
        end
    end

    always_comb begin
        unique case (vreg_a)
            5'(RI_HESYNC):  vreg_q = hesync;
            5'(RI_HEBLNK):  vreg_q = heblnk;
            5'(RI_HSBLNK):  vreg_q = hsblnk;
            5'(RI_HTOTAL):  vreg_q = htotal;
            5'(RI_VESYNC):  vreg_q = vesync;
            5'(RI_VEBLNK):  vreg_q = veblnk;
            5'(RI_VSBLNK):  vreg_q = vsblnk;
            5'(RI_VTOTAL):  vreg_q = vtotal;
            5'(RI_DPYCTL):  vreg_q = dpyctl;
            5'(RI_DPYSTRT): vreg_q = dpystrt;
            5'(RI_DPYINT):  vreg_q = dpyintr;
            5'(RI_DPYTAP):  vreg_q = dpytap;
            5'(RI_HCOUNT):  vreg_q = hcount_q;
            5'(RI_VCOUNT):  vreg_q = {7'd0, vline};
            5'(RI_DPYADR):  vreg_q = dpyadr;
            default:        vreg_q = 16'd0;
        endcase
    end
    assign env = dpyctl[15];

    // ------------------------------------------------ the line-ahead fetch
    // At dot 0 of line v: the address line v+1 will show is DPYADR after this
    // line's step (if this line is visible), or DPYADR as it stands.
    wire [15:0] adr_next = vis_y ? dpy_step(dpyadr, dpyctl, dpystrt) : dpyadr;
    wire [15:0] da_next  = dpyctl[10] ? adr_next : (adr_next ^ 16'hfffc);
    // rowaddr = da >> 4, of which (rowaddr << 9) & 0x3fe00 keeps 9 bits;
    // column = (coladdr << 1) & 0x1ff, coladdr = ((da & 0x7c) << 4) | DPYTAP
    wire  [8:0] row_next = da_next[12:4];
    wire  [8:0] col_next = 9'({da_next[3:2], 7'd0} | {dpytap[7:0], 1'b0});

    logic        fetching, show_sel, fill_sel;
    logic        vis_n, vis_c;              // line v+1 / line v is to be shown
    logic  [8:0] col_n, col_c;

    always_ff @(posedge clk) begin
        if (rst) begin
            fetching <= 1'b0; b_req <= 1'b0; fill_sel <= 1'b0; show_sel <= 1'b1;
            vis_n <= 1'b0; vis_c <= 1'b0; late <= '0;
        end else begin
            if (sol) begin
                // the line now starting shows what was fetched during the last one
                show_sel <= fill_sel;
                vis_c    <= vis_n;
                col_c    <= col_n;
                if (fetching && vis_n && late != 16'hffff) late <= late + 16'd1;
                // and the next line's fetch starts
                fill_sel <= ~fill_sel;
                vis_n    <= vis_line(vnext, veblnk, vsblnk) && dpyctl[15];
                col_n    <= col_next;
                if (vis_line(vnext, veblnk, vsblnk) && dpyctl[15]) begin
                    b_addr   <= 24'(VRAM_W + {6'd0, row_next, 9'd0});
                    b_len    <= 10'd512;
                    b_req    <= 1'b1;
                    fetching <= 1'b1;
                end
            end
            if (b_done) begin
                b_req    <= 1'b0;
                fetching <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------- line buffers
    // {buffer, column}: one RAM, one dimension, a power of two (5.18)
    logic  [8:0] rd_col;
    logic [15:0] lb_q;
    sdpram #(.AW(10), .DW(16)) u_line (
        .clk(clk), .we(b_wr), .waddr({fill_sel, b_idx[8:0]}), .wdata(b_data),
        .raddr({show_sel, rd_col}), .q(lb_q)
    );
    wire [8:0] dot_x = 9'(hdot - hbl_end);
    always_ff @(posedge clk) if (cen_dot) rd_col <= 9'(col_c + dot_x);

    // ------------------------------------------------------------ palette
    wire [14:0] pen_w = lb_q[14:0];
    logic [15:0] pv_q;
    dpram_be #(.AW(15)) u_pal (
        .clk(clk),
        .a_addr(pal_a), .a_we(pal_we), .a_be(pal_be), .a_wdata(pal_d), .a_rdata(pal_q),
        .b_addr(pen_w), .b_we(1'b0), .b_be(2'b00), .b_wdata(16'd0), .b_rdata(pv_q)
    );

    // 5 bits to 8 by replication: MAME's pal5bit
    function automatic logic [7:0] pal5(input logic [4:0] v);
        return {v, v[4:2]};
    endfunction

    // ------------------------------------------------------------ output
    // dot n's address at dot n, line buffer then palette inside its twelve
    // clocks, colour registered at dot n+1 with everything that goes with it
    logic vis_p, hbl_p, hsy_p;
    always_ff @(posedge clk) begin
        if (cen_dot) begin
            rgb    <= vis_p ? {pal5(pv_q[14:10]), pal5(pv_q[9:5]), pal5(pv_q[4:0])} : 24'h000000;
            de     <= vis_p;
            hblank <= hbl_p;
            hsync  <= hsy_p;
            pen    <= pen_w;
            vis_p  <= vis_x && vis_y && vis_c;
            hbl_p  <= !vis_x;
            hsy_p  <= (hdot <= hsy_end);
        end
    end
    assign vblank = !vis_y;
    assign vsync  = (vline <= vesync[8:0]);

    // --------------------------------------------------------- interrupt
    assign dpyint = sol && dpyctl[15] && (vline == dpyintr[8:0]);
endmodule

`default_nettype wire
