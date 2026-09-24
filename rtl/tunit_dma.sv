//------------------------------------------------------------------------------
// The T-unit DMA blitter (docs/hardware.md section 7.3).
//
// MAME's dma_draw draws a whole blit at once.  Here VRAM is SDRAM, so a blit
// is drawn a destination row at a time, in three phases per row, each an
// SDRAM burst or a pass over block RAM:
//
//   READ   burst the source bits the row needs into the source buffer
//          (skipped when neither pixel action looks at the pixel value)
//   GEN    one destination pixel per clock into a 1024-entry row buffer
//          indexed by x, each entry {written, value}
//   WRITE  burst the span of x that was written, byte enables from the
//          written flag, clearing each entry as it goes out
//
// The per-row arithmetic is MAME's, simplified by two facts that follow from
// it (tools/dma_model.py is the executable version, checked against MAME):
//
//   * every row of a blit has the same pixel count and the same source
//     pattern: ix starts at tx0 (the start skip, rounded down to a multiple
//     of xstep) and steps by xstep while below lim (the width less the end
//     skip), and dest pixel k reads source pixel (ix_k >> 8) of the row, at
//     bit offset row_off + bpp * (ix_k >> 8);
//   * rows advance row_off by ((iy + ystep) >> 8 - iy >> 8) * width * bpp,
//     which covers the unscaled case with ystep = 0x100.
//
// A destination pixel is vram[sy * 512 + sx], sx 10 bits: 512-1023 lands in
// the next row, exactly as MAME's d[sx] does.
//
// Skip mode (command bit 7; the match-up screen's portraits use it): every
// source row starts with a byte whose nibbles, shifted by the pre/post skip
// sizes, are pixels to leave out at each end.  The row's geometry is only
// known once that byte is read, so a skip-mode row reads its whole window
// (header + width * bpp bits), decodes the header (S_HDR*), and then runs
// GEN from the header's start.  Only the unscaled form is implemented: with
// scaling MAME chases the headers of the rows the y step skips, and that is
// counted in stat_skipmode rather than drawn right.
//
// Completion is paced to MAME's: dma_w sets a timer of 41 ns x pixels, with
// pixels = width x height (unscaled), (width*256/xstep) x (height*256/ystep)
// (scaled), and only when it fires is DMA_COMMAND bit 15 cleared and INT1
// raised -- whether or not anything was drawn (op 0 blits still take their
// time).  This blitter usually draws faster than that; it then waits.  So the
// game's polling loops see what MAME's saw, and whatever they feed (the
// title screen's static is seeded from timing) stays in step.  Smash TV's
// blitter is paced to the same 41 ns, for the same reason.
//
// Cancel: the game's vblank handler writes 0 to the command register when a
// blit is still running (hardware.md 7.4).  A write to the command register
// while busy stops the blit at the next phase boundary (never mid-burst) and
// then starts the new command if it has bit 15 set, else finishes.
//------------------------------------------------------------------------------
`default_nettype none

module tunit_dma #(
    parameter logic [24:1] GFX_W  = 24'h000000,  // graphics ROM word 0
    parameter logic [24:1] VRAM_W = 24'h800000   // VRAM pixel 0
) (
    input  logic        clk,
    input  logic        reset,

    // CPU register port: register r is the 16-bit word at 01a8_0000 + 16 r
    input  logic        reg_wr,         // one-clock pulse
    input  logic  [3:0] reg_addr,
    input  logic [15:0] reg_wdata,
    input  logic  [1:0] reg_be,
    output logic [15:0] reg_rdata,
    output logic [15:0] palette,        // DMA_PALETTE, for the CPU's VRAM writes
    output logic        irq,            // TMS34010 INT1

    // SDRAM burst port (sdram_ctrl's, through nbajam_mem's arbiter)
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
    input  logic  [9:0] b_wpre,         // sdram_ctrl's lookahead index (FAST_BURST)

    // status
    output logic        busy,
    output logic [15:0] stat_skipmode   // scaled skip-mode blits (not drawn exactly), saturating
);
    localparam logic [1:0] A_SKIP = 2'd0, A_COPY = 2'd1, A_COLOR = 2'd2;
    localparam int PIECE = 256;          // words per SDRAM burst request

    // ------------------------------------------------------------ registers
    // 0..15 as the CPU writes them; 16, 17 the LEFTCLIP / RIGHTCLIP
    // pseudo-registers that offsets 12 and 13 reach when CONFIG bit 5 is 0.
    logic [15:0] regs [32];
    wire  [4:0]  wr_reg = (!regs[15][5] && (reg_addr == 4'd12 || reg_addr == 4'd13))
                          ? {1'b1, 3'b000, reg_addr[0]} : {1'b0, reg_addr};
    wire  [15:0] cur_wr = regs[wr_reg];
    wire  [15:0] merged = {reg_be[1] ? reg_wdata[15:8] : cur_wr[15:8],
                           reg_be[0] ? reg_wdata[7:0]  : cur_wr[7:0]};
    // reads of register 0 return register 1 (midtunit dma_r)
    assign reg_rdata = regs[(reg_addr == 4'd0) ? 5'd1 : {1'b0, reg_addr}];
    assign palette   = regs[8];

    // ------------------------------------------------------------ start values
    // dma_w's derivations, from the registers as they stand
    wire  [15:0] c_cmd = regs[1];
    wire  [31:0] go_raw = (c_cmd[3:0] == 4'hc) ? 32'd0 : {regs[3], regs[2]};
    wire  [31:0] go_1   = (go_raw >= 32'h0200_0000) ? go_raw - 32'h0200_0000 : go_raw;
    wire  [31:0] go_adj = (go_1   >= 32'hf800_0000) ? go_1   - 32'hf800_0000 : go_1;
    wire  [15:0] sskip  = c_cmd[6] ? {8'd0, regs[0][7:0]}  : 16'd0;
    wire  [15:0] eskip  = c_cmd[6] ? {8'd0, regs[0][15:8]} : regs[0];
    wire  [19:0] lim_c  = (eskip == 16'd0)                  ? {2'd0, regs[6][9:0], 8'd0}
                        : ({6'd0, regs[6][9:0]} > eskip)    ? {2'd0, 10'(regs[6][9:0] - eskip[9:0]), 8'd0}
                                                            : 20'd0;
    wire   [3:0] bpp_c  = (c_cmd[14:12] == 3'd0) ? 4'd8 : {1'b0, c_cmd[14:12]};

    // ------------------------------------------------------------ per blit
    logic  [3:0] bpp;                // 1..8
    logic  [7:0] pmask;
    logic        xflip, yflip;
    logic  [1:0] zact, nzact;
    logic        need_data;
    logic [15:0] pal, colorv;
    logic [15:0] xs, ys;
    logic  [9:0] bw;                 // width
    logic [17:0] hlim;               // height << 8
    logic  [9:0] xpos;
    logic  [8:0] topc, botc;
    logic  [9:0] lclip, rclip;
    logic [19:0] ix0, lim;
    logic  [7:0] s_first;
    logic [12:0] wb;                 // width * bpp: source bits per unscaled row
    logic [12:0] rowbits;            // bpp * the source pixels a row spans
    logic        skipm;              // skip mode
    logic  [1:0] preskip, postskip;
    logic  [7:0] ss_l;               // start skip
    logic [15:0] es_l;               // end skip

    // ------------------------------------------------------------ per row
    logic [19:0] iy;
    logic  [8:0] sy;
    logic [31:0] row_off;
    logic [27:0] word_lo;
    logic [19:0] lim_r;              // this row's limit for ix
    logic [13:0] row_adv;            // skip mode: bits to the next row
    logic  [6:0] pre_u, post_u;      // skip mode: this row's header, in pixels
    logic [12:0] pp_r, pq_r;         // bpp * pre_u, bpp * post_u
    logic        ssgt;               // the start skip reaches past pre
    logic signed [17:0] wrow_r, wes_r;
    // per-blit products, so no row or pixel does a multiply (96 MHz)
    logic [15:0] dv_qf;              // the start-skip quotient, registered
    logic [11:0] bs_first;           // bpp * s_first
    logic [11:0] bss;                // bpp * start skip
    logic [10:0] stepA, stepB;       // gp's step: bpp * (xs >> 8), and one pixel more
    logic  [9:0] pix_diff;           // source pixels a row spans
    logic [31:0] bit_lo_r, bit_end_r;
    logic  [7:0] hdr;
    logic  [9:0] nwords;

    // ------------------------------------------------------------ buffers
    // Source: up to 513 words, even and odd words in separate RAMs so a
    // pixel that straddles two words reads both in one clock.
    logic        sb_we;
    logic  [9:0] sb_widx;
    logic [15:0] sb_wdata;
    logic  [8:0] sb_raddr_e, sb_raddr_o;
    logic [15:0] sb_qe, sb_qo;
    sdpram #(.AW(9), .DW(16)) u_src_e (.clk(clk), .we(sb_we && !sb_widx[0]), .waddr(sb_widx[9:1]),
                                       .wdata(sb_wdata), .raddr(sb_raddr_e), .q(sb_qe));
    sdpram #(.AW(9), .DW(16)) u_src_o (.clk(clk), .we(sb_we &&  sb_widx[0]), .waddr(sb_widx[9:1]),
                                       .wdata(sb_wdata), .raddr(sb_raddr_o), .q(sb_qo));
    // Destination row, indexed by sx: {written, pixel}
    logic        db_we;
    logic  [9:0] db_waddr, db_raddr;
    logic [16:0] db_wdata, db_q;
    sdpram #(.AW(10), .DW(17)) u_dst (.clk(clk), .we(db_we), .waddr(db_waddr),
                                      .wdata(db_wdata), .raddr(db_raddr), .q(db_q));

    // ------------------------------------------------------------ state
    typedef enum logic [4:0] {
        S_IDLE, S_START, S_DIV, S_PREP, S_ROW, S_RD, S_RDGAP, S_GEN, S_DRAIN,
        S_WR, S_WRGAP, S_ADV, S_DONE, S_HDR1, S_HDR2, S_HDR3, S_HDR4, S_TDIV, S_TSET, S_RWAIT,
        S_DIVM, S_PREP2, S_ROW2, S_ROW3, S_HDR5, S_HDR6, S_TSET2
    } state_t;
    state_t      state;
    logic        cancel;             // the command register was written while busy
    logic        restart;            // ... with bit 15 set: start it when the old one stops

    // MAME's completion time, in clocks: pixels x 41 ns x 96 MHz = x 3.936
    logic [31:0] pace_cnt, pace_target;
    logic [19:0] mame_px_w, mame_px_h;   // the two factors of MAME's pixel count
    logic [39:0] mame_px;
    logic        tdiv_y;                 // which factor the timing divider is on
    logic [17:0] td_num, td_q;
    logic [16:0] td_rem;
    logic  [4:0] td_n;
    wire  [17:0] td_r   = {td_rem[16:0], td_num[17]};
    wire         td_ge  = ({1'b0, td_r} >= {3'b0, (tdiv_y ? ys : xs)});

    // divider for the start skip: q = (ss << 8) / xs, restoring, 16 steps
    logic [15:0] dv_num, dv_q;
    logic [16:0] dv_rem;
    logic  [4:0] dv_n;
    wire  [16:0] dv_r  = {dv_rem[15:0], dv_num[15]};
    wire         dv_ge = (dv_r >= {1'b0, xs});

    // burst bookkeeping
    logic [10:0] done_w;             // words (or pixels) done in this phase
    logic [10:0] piece;              // length of the burst in flight
    logic  [9:0] widx_prev;

    // GEN phase
    logic [19:0] gix;
    logic [13:0] gp;                 // bit position within the source buffer
    logic  [9:0] gsx;
    logic        s1_v, s2_v;
    logic  [3:0] s1_sh;
    logic        s1_odd;
    logic  [9:0] s1_sx, s2_sx;
    logic [15:0] s2_val;
    logic        s2_wr;
    logic  [9:0] wlo, whi;
    logic        any_wr;

    // source pixel extraction (stage 2)
    wire  [15:0] s_lo  = s1_odd ? sb_qo : sb_qe;
    wire  [15:0] s_hi  = s1_odd ? sb_qe : sb_qo;
    wire  [31:0] s_win = {s_hi, s_lo} >> s1_sh;
    wire   [7:0] s_pix = s_win[7:0] & pmask;
    wire   [1:0] s_act = (s_pix == 8'd0) ? zact : nzact;
    wire  [15:0] s_val = (s_act == A_COLOR) ? (pal | colorv) : (pal | {8'd0, s_pix});
    wire         s_in  = (s1_sx >= lclip) && (s1_sx <= rclip);

    // next-step arithmetic
    wire  [19:0] gix_n = gix + {4'd0, xs};
    wire   [8:0] gfrac = {1'b0, gix[7:0]} + {1'b0, xs[7:0]};
    wire  [19:0] iy_n  = iy + {4'd0, ys};
    wire   [8:0] gdy   = 9'(iy_n[19:8] - iy[19:8]);
    // The next row's source step, gdy x width x bpp, is computed in registers
    // during the row (iy only changes in S_ADV) rather than in S_ADV itself:
    // add, subtract, multiply and a 32-bit add in one clock missed 96 MHz by
    // 4 ns (the second compile's every worst path).  S_RWAIT gives it the
    // two clocks it needs after iy moves.
    logic  [8:0] gdy_q;
    logic [31:0] row_step;

    // row geometry
    wire  [18:0] vrow    = {sy, 10'd0} >> 1;                 // sy * 512
    wire  [10:0] wcount  = {1'b0, whi} - {1'b0, wlo} + 11'd1; // pixels in the written span
    wire  [10:0] rd_left = {1'b0, nwords} - done_w;
    wire  [10:0] wr_left = wcount - done_w;
    wire  [10:0] rd_piece = (rd_left > 11'(PIECE)) ? 11'(PIECE) : rd_left;
    wire  [10:0] wr_piece = (wr_left > 11'(PIECE)) ? 11'(PIECE) : wr_left;

    assign busy = (state != S_IDLE);
    assign b_we = (state == S_WR);

    always_ff @(posedge clk) begin
        sb_we <= 1'b0;
        db_we <= 1'b0;
        gdy_q    <= gdy;
        row_step <= 32'(gdy_q * wb);
        // before the state machine, so S_START's reset of it wins
        if (pace_cnt != 32'hffff_ffff) pace_cnt <= pace_cnt + 32'd1;

        // ---------------------------------------------- CPU writes
        if (reg_wr) begin
            regs[wr_reg] <= merged;
            if (wr_reg == 5'd1) begin
                irq <= 1'b0;
                if (busy) begin
                    cancel  <= 1'b1;
                    restart <= merged[15];
                end
            end
        end

        case (state)
            S_IDLE: begin
                // a command with bit 15 set, written this clock, starts next clock
                if (reg_wr && wr_reg == 5'd1 && merged[15]) state <= S_START;
            end

            S_START: begin
                // latch the blit (dma_w's m_dma_state)
                cancel <= 1'b0; restart <= 1'b0;
                bpp    <= bpp_c;
                pmask  <= 8'((9'd1 << bpp_c) - 9'd1);
                xflip  <= c_cmd[4];
                yflip  <= c_cmd[5];
                zact   <= c_cmd[2] ? A_COLOR : c_cmd[0] ? A_COPY : A_SKIP;
                nzact  <= c_cmd[3] ? A_COLOR : c_cmd[1] ? A_COPY : A_SKIP;
                need_data <= c_cmd[0] || c_cmd[1] || (c_cmd[2] != c_cmd[3]);
                pal    <= regs[8] & 16'h7f00;
                colorv <= {8'd0, regs[9][7:0]};
                xs     <= (regs[10] == 16'd0) ? 16'h0100 : regs[10];
                ys     <= (regs[11] == 16'd0) ? 16'h0100 : regs[11];
                bw     <= regs[6][9:0];
                hlim   <= {regs[7][9:0], 8'd0};
                xpos   <= regs[4][9:0];
                sy     <= regs[5][8:0];
                topc   <= regs[12][8:0];
                botc   <= regs[13][8:0];
                lclip  <= regs[16][9:0];
                rclip  <= regs[17][9:0];
                skipm    <= c_cmd[7];
                preskip  <= c_cmd[9:8];
                postskip <= c_cmd[11:10];
                ss_l     <= sskip[7:0];
                es_l     <= eskip;
                if (c_cmd[7] && (regs[10] != 16'd0 && regs[10] != 16'h0100 || regs[11] != 16'd0 && regs[11] != 16'h0100)
                    && stat_skipmode != 16'hffff) stat_skipmode <= stat_skipmode + 16'd1;
                row_off <= go_adj;
                lim     <= lim_c;
                iy      <= 20'd0;
                pace_cnt <= '0;
                // MAME's pixel count: offset out of range -> 0 (skipdma);
                // otherwise w x h, or with scaling the two quotients
                if (go_adj >= 32'h1000_0000) begin
                    mame_px_w <= '0; mame_px_h <= '0; state <= S_TSET;
                end else if ((regs[10] == 16'd0 || regs[10] == 16'h0100) && (regs[11] == 16'd0 || regs[11] == 16'h0100)) begin
                    mame_px_w <= {10'd0, regs[6][9:0]}; mame_px_h <= {10'd0, regs[7][9:0]}; state <= S_TSET;
                end else begin
                    tdiv_y <= 1'b0; td_num <= {regs[6][9:0], 8'd0}; td_rem <= '0; td_q <= '0; td_n <= 5'd18;
                    state <= S_TDIV;
                end
            end

            // MAME's scaled count, (w << 8) / xstep then (h << 8) / ystep
            S_TDIV: begin
                td_num <= {td_num[16:0], 1'b0};
                td_rem <= td_ge ? 17'(td_r - {2'b0, (tdiv_y ? ys : xs)}) : td_r[16:0];
                td_q   <= {td_q[16:0], td_ge};
                td_n   <= td_n - 5'd1;
                if (td_n == 5'd1) begin
                    if (!tdiv_y) begin
                        mame_px_w <= {2'd0, td_q[16:0], td_ge};
                        tdiv_y <= 1'b1; td_num <= hlim;
                        td_rem <= '0; td_q <= '0; td_n <= 5'd18;
                    end else begin
                        mame_px_h <= {2'd0, td_q[16:0], td_ge};
                        state <= S_TSET;
                    end
                end
            end
            S_TSET: begin
                // clocks = pixels x 3.936 (41 ns at 96 MHz), as pixels x 4031 / 1024,
                // over two states (in one it missed 96 MHz)
                mame_px <= 40'(mame_px_w) * 40'(mame_px_h);
                state   <= S_TSET2;
            end
            S_TSET2: begin
                pace_target <= 32'((52'(mame_px) * 52'd4031) >> 10);
                // nothing to draw: op 0, or an offset out of range
                if (c_cmd[3:0] == 4'd0 || go_adj >= 32'h1000_0000) state <= S_DONE;
                else if (sskip != 16'd0) begin
                    dv_num <= {sskip[7:0], 8'd0};
                    dv_rem <= '0;
                    dv_q   <= '0;
                    dv_n   <= 5'd16;
                    state  <= S_DIV;
                end else begin
                    ix0   <= 20'd0;
                    state <= S_PREP;
                end
            end

            S_DIV: begin
                // restoring division, one quotient bit a clock
                dv_num <= {dv_num[14:0], 1'b0};
                dv_rem <= dv_ge ? dv_r - {1'b0, xs} : dv_r;
                dv_q   <= {dv_q[14:0], dv_ge};
                dv_n   <= dv_n - 5'd1;
                if (dv_n == 5'd1) begin
                    dv_qf <= {dv_q[14:0], dv_ge};
                    state <= S_DIVM;
                end
            end
            S_DIVM: begin
                ix0   <= 20'(dv_qf * xs);
                state <= S_PREP;
            end

            S_PREP: begin
                // the source window every row shares, and the per-blit products
                s_first  <= ix0[15:8];
                pix_diff <= 10'(lim[19:8] - {4'd0, ix0[15:8]});
                wb       <= 13'(bpp * bw);
                bs_first <= 12'(bpp * ix0[15:8]);
                bss      <= 12'(bpp * ss_l);
                stepA    <= 11'(bpp * xs[15:8]);
                state    <= (!skipm && ix0 >= lim) ? S_DONE : S_PREP2;
            end
            S_PREP2: begin
                rowbits <= 13'(bpp * pix_diff);
                stepB   <= stepA + {7'd0, bpp};
                state   <= S_ROW;
            end

            S_ROW: begin
                done_w <= '0;
                any_wr <= 1'b0;
                wlo <= 10'h3ff; whi <= 10'h000;
                // one 32-bit add a state from here on (96 MHz)
                bit_lo_r <= skipm ? row_off : row_off + {20'd0, bs_first};
                if (cancel) state <= S_DONE;
                else if (!skipm && (sy < topc || sy > botc)) state <= S_ADV;     // clipped row
                else state <= S_ROW2;
            end
            S_ROW2: begin
                bit_end_r <= skipm ? bit_lo_r + 32'd7 + {19'd0, wb}
                                   : bit_lo_r + {19'd0, rowbits} - 32'd1;
                state <= S_ROW3;
            end
            S_ROW3: begin
                word_lo <= bit_lo_r[31:4];
                gp      <= {10'd0, bit_lo_r[3:0]};
                if (skipm) begin
                    // the header and the whole row; only the header if the row is clipped
                    nwords <= (sy < topc || sy > botc) ? 10'd2
                            : 10'(bit_end_r[31:4] - bit_lo_r[31:4] + 28'd1);
                    state  <= S_RD;
                end else begin
                    nwords <= 10'(bit_end_r[31:4] - bit_lo_r[31:4] + 28'd1);
                    state  <= need_data ? S_RD : S_GEN;
                    gix    <= ix0;
                    gsx    <= xpos;
                    lim_r  <= lim;
                end
            end

            // ---- skip mode: the row's header byte, then its geometry
            S_HDR1: begin
                s1_sh  <= gp[3:0];
                s1_odd <= gp[4];
                state  <= S_HDR2;
            end
            S_HDR2: begin
                hdr    <= s_win[7:0];
                state  <= S_HDR3;
            end
            S_HDR3: begin : hdr3
                // dma_draw's Skip block, unscaled (xstep = 0x100): pre and post in
                // pixels, and the products the rest needs, all registered here
                logic [6:0] pre, post;
                pre  = 7'({3'd0, hdr[3:0]} << preskip);
                post = 7'({3'd0, hdr[7:4]} << postskip);
                pre_u  <= pre;
                post_u <= post;
                pp_r   <= 13'(bpp * pre);
                pq_r   <= 13'(bpp * post);
                ssgt   <= ({1'b0, ss_l} > {2'd0, pre});
                state  <= S_HDR4;
            end
            S_HDR4: begin
                // the start skip applies past pre; the end skip clamps the width
                // that post has already shortened (finished in S_HDR5)
                wrow_r <= 18'($signed({8'd0, bw}) - $signed({11'd0, post_u}));
                wes_r  <= 18'($signed({8'd0, bw}) - $signed({2'd0, es_l}));
                if (ssgt) begin
                    gix <= {4'd0, ss_l, 8'd0};
                    gp  <= gp + 14'd8 + 14'(bss) - 14'(pp_r);
                end else begin
                    gix <= {5'd0, pre_u, 8'd0};
                    gp  <= gp + 14'd8;
                end
                gsx <= xflip ? xpos - {3'd0, pre_u} : xpos + {3'd0, pre_u};
                state <= S_HDR5;
            end
            S_HDR5: begin : hdr5
                logic signed [17:0] wl;
                wl = (es_l != 16'd0 && wrow_r > wes_r) ? wes_r : wrow_r;
                lim_r <= (wl > 0) ? {2'd0, wl[9:0], 8'd0} : 20'd0;
                // 8 + bpp * (width - pre - post), as 8 + wb - bpp*pre - bpp*post
                row_adv <= 14'd8 + ((wb > pp_r + pq_r) ? 14'(wb - pp_r - pq_r) : 14'd0);
                state <= S_HDR6;
            end
            S_HDR6: state <= (sy < topc || sy > botc || gix >= lim_r) ? S_ADV : S_GEN;

            // ---- READ: bursts of up to PIECE words into the source buffer
            S_RD: begin
                piece  <= rd_piece;
                b_addr <= 24'(GFX_W + 24'(word_lo + {17'd0, done_w}));
                b_len  <= rd_piece[9:0];
                b_req  <= 1'b1;
                if (b_wr) begin
                    // words past the 8 MB ROM read as zero, as MAME's region does
                    sb_we    <= 1'b1;
                    sb_widx  <= 10'(done_w + {1'b0, b_idx});
                    sb_wdata <= ((word_lo + {17'd0, done_w} + {18'd0, b_idx}) >= 28'h40_0000) ? 16'd0 : b_data;
                end
                if (b_done) begin
                    b_req  <= 1'b0;
                    done_w <= done_w + piece;
                    state  <= S_RDGAP;
                end
            end
            S_RDGAP: begin
                // the controller wants b_req low for a clock between bursts
                state <= (done_w < {1'b0, nwords}) ? S_RD : skipm ? S_HDR1 : S_GEN;
            end

            // ---- GEN: one pixel a clock, three stages
            S_GEN: begin
                // stage 1: address the two source words
                s1_v   <= 1'b1;
                s1_sh  <= gp[3:0];
                s1_odd <= gp[4];
                s1_sx  <= gsx;
                gix <= gix_n;
                // (gix + xs) >> 8 - gix >> 8 is xs >> 8, plus one when the fraction
                // carries: two precomputed steps, no multiply in the loop
                gp  <= gp + {3'd0, gfrac[8] ? stepB : stepA};
                gsx <= xflip ? gsx - 10'd1 : gsx + 10'd1;
                if (gix_n >= lim_r || cancel) state <= S_DRAIN;
            end
            S_DRAIN: begin
                s1_v <= 1'b0;
                done_w <= '0;
                if (!s1_v && !s2_v) state <= any_wr ? S_WR : S_ADV;
            end

            // ---- WRITE: bursts of the written span, byte enables from the flags
            S_WR: begin
                piece  <= wr_piece;
                b_addr <= 24'(VRAM_W + 24'({5'd0, vrow} + {14'd0, wlo} + {13'd0, done_w}));
                b_len  <= wr_piece[9:0];
                b_req  <= 1'b1;
                // clear each entry once it has gone out (see the header)
                if (b_widx == widx_prev + 10'd1) begin
                    db_we    <= 1'b1;
                    db_waddr <= 10'({1'b0, wlo} + done_w + {1'b0, widx_prev});
                    db_wdata <= '0;
                end
                if (b_done) begin
                    b_req  <= 1'b0;
                    done_w <= done_w + piece;
                    state  <= S_WRGAP;
                end
            end
            S_WRGAP: state <= (done_w >= wcount) ? S_ADV : S_WR;

            S_ADV: begin
                iy      <= iy_n;
                row_off <= row_off + (skipm ? {18'd0, row_adv} : row_step);
                sy      <= yflip ? sy - 9'd1 : sy + 9'd1;
                done_w  <= '0;
                state   <= (iy_n >= {2'd0, hlim} || cancel) ? S_DONE : S_RWAIT;
            end
            S_RWAIT: begin
                state   <= S_ROW;
            end

            S_DONE: begin
                // a command written on this very clock is not lost: with bit 15
                // it starts, without it simply lands in the register
                if ((cancel && restart) || (reg_wr && wr_reg == 5'd1 && merged[15]))
                    state <= S_START;
                else if (pace_cnt < pace_target) begin
                    // drawn; MAME's timer has not fired yet
                end else begin
                    if (!(reg_wr && wr_reg == 5'd1)) regs[1][15] <= 1'b0;
                    irq   <= 1'b1;
                    state <= S_IDLE;
                end
                cancel <= 1'b0;
            end
            default: state <= S_IDLE;
        endcase

        // stage 2: the source words are out of the RAMs
        s2_v   <= s1_v && (state == S_GEN || state == S_DRAIN);
        s2_sx  <= s1_sx;
        s2_val <= s_val;
        s2_wr  <= (s_act != A_SKIP) && s_in;
        // stage 3: into the row buffer
        if (s2_v && s2_wr) begin
            db_we    <= 1'b1;
            db_waddr <= s2_sx;
            db_wdata <= {1'b1, s2_val};
            any_wr   <= 1'b1;
            if (s2_sx < wlo) wlo <= s2_sx;
            if (s2_sx > whi) whi <= s2_sx;
        end
        if (state != S_GEN) s1_v <= 1'b0;

        widx_prev <= b_widx;

        if (reset) begin
            state <= S_IDLE;
            irq <= 1'b0;
            cancel <= 1'b0; restart <= 1'b0;
            b_req <= 1'b0;
            s1_v <= 1'b0; s2_v <= 1'b0;
            stat_skipmode <= '0;
            for (int i = 0; i < 32; i++) regs[i] <= '0;
        end
    end

`ifdef BLIT_TRACE
    state_t st_q;
    always_ff @(posedge clk) begin
        st_q <= state;
        if (state != st_q && st_q != S_GEN)
            $display("dma %0d -> %0d sy=%0d iy=%h row_off=%h nwords=%0d gix=%h lim=%h wlo=%0d whi=%0d any=%0d done_w=%0d",
                     st_q, state, sy, iy, row_off, nwords, gix, lim, wlo, whi, any_wr, done_w);
        if (b_done) $display("  b_done we=%0d addr=%h len=%0d", b_we, b_addr, b_len);
    end
`endif

    // source buffer read addresses: words w and w + 1 of the pixel at gp
    always_comb begin
        logic [9:0] w;
        w = gp[13:4];
        sb_raddr_e = 9'((w + 10'd1) >> 1);
        sb_raddr_o = w[9:1];
    end

    // destination buffer read, for the write burst
    // addressed with the controller's lookahead so a word a clock can go out
    assign db_raddr = 10'({1'b0, wlo} + done_w + {1'b0, b_wpre});
    assign b_wdata  = db_q[15:0];
    assign b_be     = {2{db_q[16]}};
endmodule

`default_nettype wire
