//------------------------------------------------------------------------------
// The T-unit main board: the TMS34010, its address decode, the blitter, the
// scan-out, the CMOS, the protection and the sound latch, wired the way
// docs/hardware.md section 2 maps them.  The pattern is Smash TV's
// stv_main.sv: one bus transaction at a time -- the CPU raises bus_req, the
// decoder hands it to one target, the target's ack comes back as the CPU's.
//
// Memory leaves this module as two ports, so the same module sits on ideal
// memories in the fast bench and on target/pocket/nbajam_mem.sv in the core:
//
//   sd_*   one random-access SDRAM client for the CPU: program ROM, work RAM,
//          VRAM (a CPU word is two pixels, so two accesses) and the CPU's
//          window on the graphics ROM
//   b_*    one burst port, shared by the scan-out line fetch, the shift
//          register (NBA Jam's per-frame page clear) and the blitter, in that
//          priority, the owner latched at grant and every response routed by
//          it (METHODOLOGY 5.17)
//
// SDRAM word map (docs/core-design.md 4): graphics 0x000000, program
// 0x400000, VRAM 0x800000 (pixel p at + p), work RAM 0xC00000.
//------------------------------------------------------------------------------
`default_nettype none

module tunit_main #(
    parameter logic [24:1] GFX_W  = 24'h000000,
    parameter logic [24:1] PROG_W = 24'h400000,
    parameter logic [24:1] VRAM_W = 24'h800000,
    parameter logic [24:1] RAM_W  = 24'hC00000
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_cpu,        // 6.25 MHz machine cycles
    input  logic        cen_dot,        // 8 MHz dots
    input  logic        te,             // Tournament Edition: its protection (static after the load)

    // ---------------- SDRAM, random access (the CPU)
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

    // ---------------- the cabinet, active low
    input  logic [15:0] in0, in1, in2, dsw,

    // ---------------- to the sound board (docs/hardware.md 5)
    output logic  [7:0] snd_cmd,
    output logic        snd_strobe,     // pulse: a command was written
    output logic        snd_reset,      // level: bit 8 of the last write was low

    // ---------------- picture
    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank, de,

    // ---------------- CMOS, for the NVRAM save (port B of its RAM)
    input  logic [12:0] nv_addr,
    input  logic        nv_we,
    input  logic [15:0] nv_wdata,
    output logic [15:0] nv_rdata,
    output logic        nv_dirty,       // toggles on every CMOS write

    // ---------------- bring-up
    output logic [31:0] dbg_pc,
    output logic        dbg_unimpl,
    output logic [15:0] dbg_late,       // scan-out lines fetched late
    output logic [15:0] dbg_skipmode,   // scaled skip-mode blits (not drawn exactly)
    output logic        dbg_blit_busy
);
    // ------------------------------------------------------------ the CPU
    logic        c_req, c_we, c_ack, c_srt;
    logic [31:4] c_a;
    logic [15:0] c_wd, c_rd;
    logic        blit_irq, dpyint;

    tms34010 u_cpu (
        .clk(clk), .rst(rst), .cen(cen_cpu),
        .bus_req(c_req), .bus_we(c_we), .bus_addr(c_a), .bus_wdata(c_wd),
        .bus_rdata(c_rd), .bus_ack(c_ack), .bus_srt(c_srt),
        .int1(blit_irq), .int2(1'b0), .dpyint(dpyint),
        .insn_start(), .irq_taken(), .dbg_pc(dbg_pc), .unimpl(dbg_unimpl)
    );
    wire [31:0] A = {c_a, 4'd0};

    // ------------------------------------------------------------ decode
    typedef enum logic [3:0] {
        T_ZERO, T_VRAM, T_RAM, T_CMOS, T_IN, T_PAL, T_BLIT, T_CTRL, T_PROT,
        T_SSTAT, T_SND, T_GFX, T_IO, T_ROM, T_NONE
    } tgt_t;
    tgt_t tgt;
    always_comb begin
        if      (A[31:22] == 10'd0)                              tgt = T_VRAM;   // 0000_0000-003f_ffff
        else if (A[31:22] == 10'h004)                            tgt = T_RAM;    // 0100_0000-013f_ffff
        else if (A[31:17] == 15'h00a0)                           tgt = T_CMOS;   // 0140_0000-0141_ffff
        else if (A[31:6]  == 26'h0058000)                        tgt = T_IN;     // 0160_0000-0160_003f
        else if (A[31:19] == 13'h0030)                           tgt = T_PAL;    // 0180_0000-0187_ffff
        else if (A[31:8]  == 24'h01a800)                         tgt = T_BLIT;   // 01a8_0000-01a8_00ff
        else if (prot_hit)                                       tgt = T_PROT;
        else if (A[31:5]  == 27'h00d8000 || A[31:5] == 27'h00f8000) tgt = T_CTRL; // 01b0_0000, 01f0_0000
        else if (A[31:5]  == 27'h00e8000)                        tgt = T_SSTAT;  // 01d0_0000-01d0_001f
        else if (A[31:5]  == 27'h00e8081)                        tgt = T_SND;    // 01d0_1020-01d0_103f
        else if (A[31:27] == 5'd0 && A[26:25] != 2'd0)           tgt = T_GFX;    // 0200_0000-07ff_ffff
        else if (A[31:9]  == 23'h600000)                         tgt = T_IO;     // c000_0000-c000_01ff
        else if (A[31:23] == 9'h1ff || A[31:23] == 9'h03f)       tgt = T_ROM;    // ff80_0000-, 1f80_0000-
        else                                                     tgt = T_ZERO;   // reads all ones
    end

    // ------------------------------------------------------------ registers
    logic [15:0] ctrl;                  // the control latch: bit 5 is the VRAM bank
    logic  [7:0] snd_fake;              // MAME's sound_state_r countdown

    // protection (docs/hardware.md 4.2): a five-word queue
    logic [15:0] pq [8];
    logic  [2:0] pq_i;
    // The protection answers in one window on NBA Jam, 01b1_4020-01b2_503f,
    // and in two on Tournament Edition, 01b1_5f40-01b3_7f5f and the same
    // 0x80000 higher (init_nbajam_common).  Each lies in one 0x40000 (NBA
    // Jam) or 0x80000 (TE, either copy) block, so only the low bits are
    // compared; the index is (word offset from the window's start >> 6).
    wire         prot_nba = (A[31:18] == 14'h006c) && (A[17:0] >= 18'h14020) && (A[17:0] <= 18'h2503f);
    wire         prot_te  = (A[31:20] == 12'h01b)  && (A[18:0] >= 19'h15f40) && (A[18:0] <= 19'h37f5f);
    wire         prot_hit = te ? prot_te : prot_nba;
    wire   [6:0] prot_idx = te ? 7'((A[18:0] - 19'h15f40) >> 10) : 7'((A[17:0] - 18'h14020) >> 10);
    wire  [31:0] prot_val = te ? nbajamte_prot(prot_idx) : nbajam_prot(prot_idx);

    // ------------------------------------------------------------ the parts
    logic        blit_we, vreg_we, pal_we;
    logic [15:0] blit_q, vreg_q, pal_q, blit_pal;

    // the blitter's burst port
    logic [24:1] d_addr; logic [9:0] d_len; logic d_req, d_we; logic [15:0] d_wdata; logic [1:0] d_be;
    // the scan-out's
    logic [24:1] v_addr; logic [9:0] v_len; logic v_req;
    // the shift register's
    logic [24:1] s_addr; logic [9:0] s_len; logic s_req, s_we; logic [15:0] s_wdata;

    // who owns the burst port, latched at grant (5.17)
    typedef enum logic [1:0] { O_NONE, O_VID, O_SRT, O_DMA } own_t;
    own_t own;
    wire own_vid = (own == O_VID), own_srt = (own == O_SRT), own_dma = (own == O_DMA);

    tunit_dma #(.GFX_W(GFX_W), .VRAM_W(VRAM_W)) u_dma (
        .clk(clk), .reset(rst),
        .reg_wr(blit_we), .reg_addr(A[7:4]), .reg_wdata(c_wd), .reg_be(2'b11),
        .reg_rdata(blit_q), .palette(blit_pal), .irq(blit_irq),
        .b_addr(d_addr), .b_len(d_len), .b_req(d_req), .b_we(d_we),
        .b_wdata(d_wdata), .b_be(d_be),
        .b_wr(b_wr && own_dma), .b_idx(b_idx), .b_data(b_data),
        .b_done(b_done && own_dma), .b_widx(own_dma ? b_widx : 10'd0),
        .b_wpre(own_dma ? b_wpre : 10'd0),
        .busy(dbg_blit_busy), .stat_skipmode(dbg_skipmode)
    );

    logic [14:0] pen;
    logic        env;
    tunit_video #(.RESET_TO_GAME(1'b0), .VRAM_W(VRAM_W)) u_video (
        .clk(clk), .rst(rst), .cen_dot(cen_dot),
        .vreg_we(vreg_we), .vreg_a(A[8:4]), .vreg_d(c_wd), .vreg_q(vreg_q), .env(env),
        .pal_we(pal_we), .pal_a(A[18:4]), .pal_d(c_wd), .pal_be(2'b11), .pal_q(pal_q),
        .b_addr(v_addr), .b_len(v_len), .b_req(v_req),
        .b_wr(b_wr && own_vid), .b_idx(b_idx), .b_data(b_data), .b_done(b_done && own_vid),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
        .pen(pen), .dpyint(dpyint), .late(dbg_late), .hdot_o(), .vline_o()
    );

    // CMOS: 8K words, port A the CPU, port B the NVRAM save
    logic [15:0] cmos_q;
    logic        cmos_we;
    dpram_be #(.AW(13)) u_cmos (
        .clk(clk),
        .a_addr(A[16:4]), .a_we(cmos_we), .a_be(2'b11), .a_wdata(c_wd), .a_rdata(cmos_q),
        .b_addr(nv_addr), .b_we(nv_we), .b_be(2'b11), .b_wdata(nv_wdata), .b_rdata(nv_rdata)
    );

    always_ff @(posedge clk) if (rst) nv_dirty <= 1'b0; else if (cmos_we) nv_dirty <= ~nv_dirty;

    // ---------------------------------------------- the shift register
    // MAME's to_shiftreg / from_shiftreg (midtunit_v.cpp): 1024 pixels at
    // pixel address (bit address >> 3), copied into or out of the register.
    // Done as two 512-word bursts each way (docs/hardware.md 7.4).
    //
    // A WRITE is queued and the CPU released at once: the game's page clear
    // is a FILL of 127 of them, and waiting out each 1024-word copy cost the
    // CPU ~9,000 of its 114,251 cycles a frame (measured), where MAME's are
    // instantaneous.  Order is kept: the queue has the burst port ahead of
    // the blitter, and a CPU VRAM access or a shift-register READ waits
    // until the queue is empty and the engine idle.
    logic        sr_we;
    logic  [9:0] sr_waddr, sr_raddr;
    logic [15:0] sr_q;
    sdpram #(.AW(10), .DW(16)) u_sr (
        .clk(clk), .we(sr_we), .waddr(sr_waddr), .wdata(b_data), .raddr(sr_raddr), .q(sr_q)
    );
    typedef enum logic [2:0] { SR_IDLE, SR_POP, SR_GO, SR_GAP, SR_DONE } srst_t;
    srst_t       srs;
    logic        sr_dir;                // 1 = VRAM <- register
    logic        sr_half;
    logic [18:0] sr_pix;
    logic        sr_start;              // a read: start now
    logic [18:0] sr_rd_pix;
    // the queue of writes: pixel addresses
    logic        srq_we;
    logic [18:0] srq_wdata, srq_q;
    logic  [8:0] srq_wp, srq_rp;
    sdpram #(.AW(8), .DW(19)) u_srq (
        .clk(clk), .we(srq_we), .waddr(srq_wp[7:0]), .wdata(srq_wdata), .raddr(srq_rp[7:0]), .q(srq_q)
    );
    wire         srq_empty = (srq_wp == srq_rp);
    wire         srq_full  = (srq_wp[7:0] == srq_rp[7:0]) && (srq_wp[8] != srq_rp[8]);
    wire         sr_all_idle = (srs == SR_IDLE) && srq_empty;
    assign s_addr   = 24'(VRAM_W + {5'd0, 19'(sr_pix + {9'd0, sr_half, 9'd0})});
    assign s_len    = 10'd512;
    assign s_we     = sr_dir;
    assign sr_raddr = {sr_half, own_srt ? b_wpre[8:0] : 9'd0};
    assign s_wdata  = sr_q;
    always_ff @(posedge clk) begin
        sr_we <= 1'b0;
        if (rst) begin
            srs <= SR_IDLE; s_req <= 1'b0; srq_rp <= '0;
        end else case (srs)
            SR_IDLE:
                if (sr_start)        begin sr_dir <= 1'b0; sr_pix <= sr_rd_pix; sr_half <= 1'b0; srs <= SR_GO; end
                else if (!srq_empty) srs <= SR_POP;          // the queue's head is read this clock
            SR_POP: begin
                sr_dir <= 1'b1; sr_pix <= srq_q; sr_half <= 1'b0;
                srq_rp <= srq_rp + 9'd1;
                srs <= SR_GO;
            end
            SR_GO: begin
                s_req <= 1'b1;
                if (own_srt && b_wr && !sr_dir) begin
                    sr_we <= 1'b1; sr_waddr <= {sr_half, b_idx[8:0]};
                end
                if (own_srt && b_done) begin s_req <= 1'b0; srs <= SR_GAP; end
            end
            SR_GAP: if (!sr_half) begin sr_half <= 1'b1; srs <= SR_GO; end
                    else srs <= sr_dir ? SR_IDLE : SR_DONE;      // a write is nobody's to wait for
            default: srs <= SR_IDLE;
        endcase
    end

    // ---------------------------------------------- the burst port
    always_ff @(posedge clk) begin
        if (rst) own <= O_NONE;
        else case (own)
            O_NONE: if (v_req)      own <= O_VID;
                    else if (s_req) own <= O_SRT;
                    // not while shift-register writes are queued: the game's
                    // blits into a page must land after its clear
                    else if (d_req && sr_all_idle) own <= O_DMA;
            // an owner keeps the port to the end of its burst, and hands it
            // back once it has dropped its request (the controller's gap)
            O_VID: if (!v_req) own <= O_NONE;
            O_SRT: if (!s_req) own <= O_NONE;
            O_DMA: if (!d_req) own <= O_NONE;
            default: own <= O_NONE;
        endcase
    end
    always_comb begin
        unique case (own)
            O_VID:   begin b_addr = v_addr; b_len = v_len; b_req = v_req; b_we = 1'b0;  b_wdata = 16'd0;   b_be = 2'b00; end
            O_SRT:   begin b_addr = s_addr; b_len = s_len; b_req = s_req; b_we = s_we;  b_wdata = s_wdata; b_be = 2'b11; end
            O_DMA:   begin b_addr = d_addr; b_len = d_len; b_req = d_req; b_we = d_we;  b_wdata = d_wdata; b_be = d_be;  end
            default: begin b_addr = '0;     b_len = '0;    b_req = 1'b0;  b_we = 1'b0;  b_wdata = 16'd0;   b_be = 2'b00; end
        endcase
    end

    // ---------------------------------------------- the program ROM cache
    // The real TMS34010 fetches from its own instruction cache, and MAME's
    // cycle counts assume it: a register instruction is charged one cycle
    // (15.4 clocks) INCLUDING its fetch.  Every fetch as an SDRAM round trip
    // (14-16 clocks through the controller and this bus) made the CPU finish
    // only ~87,400 of the 114,251 cycles a frame it is paced for (measured in
    // sim/run_machine.sh) -- 76% speed, and the game fell behind MAME's
    // timeline in its busier stretches.  So: 4K words, direct mapped, one
    // word a line, {valid, tag, data}.  The ROM never changes after the
    // download, so an entry can never be stale, and a BRAM powers up zero, so
    // nothing is valid before it has been filled.
    logic        ic_we;
    logic [11:0] ic_waddr;
    logic [23:0] ic_wdata, ic_q;
    sdpram #(.AW(12), .DW(24)) u_icache (
        .clk(clk), .we(ic_we), .waddr(ic_waddr), .wdata(ic_wdata),
        .raddr(A[15:4]), .q(ic_q)
    );
    wire ic_hit = ic_q[23] && (ic_q[22:16] == A[22:16]);

    // ---------------------------------------------- the work RAM cache
    // Only the CPU ever touches work RAM, so a write-through cache of it can
    // never disagree with the SDRAM.  Reads that hit answer at once; every
    // write goes to both, and the SDRAM write is POSTED: the CPU is released
    // on the clock it asks, and the next access that needs the SDRAM waits
    // for the write to land.  4K words, direct mapped, {valid, tag, data}.
    // (Measured before it: the CPU completed ~92% of its cycles on frames
    // where the blitter keeps the SDRAM busy.)
    logic        dc_we;
    logic [11:0] dc_waddr;
    logic [22:0] dc_wdata, dc_q;
    sdpram #(.AW(12), .DW(23)) u_dcache (
        .clk(clk), .we(dc_we), .waddr(dc_waddr), .wdata(dc_wdata),
        .raddr(A[15:4]), .q(dc_q)
    );
    wire dc_hit = dc_q[22] && (dc_q[21:16] == A[21:16]);
    logic posted;                       // a work-RAM write is still on its way to the SDRAM

    // ------------------------------------------------------------ the bus
    typedef enum logic [2:0] { B_IDLE, B_WAIT, B_ICK, B_DCK, B_SRT, B_DONE } bst_t;
    bst_t bst;
    tgt_t tl;
    logic [15:0] vr_lo;                 // the first pixel of a VRAM word
    logic  [1:0] pal_wait;

    // what a VRAM pixel access writes, for the bank the latch selects
    wire        bank = ctrl[5];

    always_ff @(posedge clk) begin
        c_ack      <= 1'b0;
        blit_we    <= 1'b0;
        vreg_we    <= 1'b0;
        pal_we     <= 1'b0;
        cmos_we    <= 1'b0;
        snd_strobe <= 1'b0;
        sr_start   <= 1'b0;
        ic_we      <= 1'b0;
        dc_we      <= 1'b0;
        srq_we     <= 1'b0;
        if (srq_we) srq_wp <= srq_wp + 9'd1;
        // the posted write lands; nothing else can be waiting on the port then
        if (posted && sd_ack) begin posted <= 1'b0; sd_req <= 1'b0; end
        if (rst) begin
            posted <= 1'b0; srq_wp <= '0;
            bst <= B_IDLE; ctrl <= 16'h0000; sd_req <= 1'b0;
            snd_cmd <= 8'h00; snd_reset <= 1'b0; snd_fake <= 8'd0;
            pq_i <= 3'd0; for (int i = 0; i < 8; i++) pq[i] <= 16'd0;
        end else case (bst)
            // a new access that needs the SDRAM port waits for a posted write
            // a VRAM access waits for the shift-register queue (order), and a
            // queued write for room in it
            B_IDLE: if (c_req && !(posted && (tgt == T_VRAM || tgt == T_GFX || (tgt == T_RAM && c_we)))
                              && !(tgt == T_VRAM && (c_srt && c_we ? srq_full : !sr_all_idle))) begin
                tl  <= tgt;
                bst <= B_WAIT;
                pal_wait <= 2'd0;
                case (tgt)
                    T_VRAM: begin
                        if (c_srt && c_we) begin
                            // a shift-register write: queued, the CPU released now
                            srq_we <= 1'b1; srq_wdata <= A[21:3];
                            c_ack <= 1'b1; bst <= B_DONE;
                        end else if (c_srt) begin
                            // a read: the register is loaded before the CPU goes on
                            sr_rd_pix <= A[21:3];
                            sr_start <= 1'b1;
                            bst <= B_SRT;
                        end else begin
                            // pixel 2o first
                            sd_req <= 1'b1; sd_addr <= 24'(VRAM_W + {5'd0, A[21:4], 1'b0});
                            sd_we  <= c_we;
                            sd_wdata <= bank ? {blit_pal[7:0], c_wd[7:0]} : {c_wd[7:0], 8'h00};
                            sd_be  <= bank ? 2'b11 : 2'b10;
                        end
                    end
                    T_RAM: begin
                        if (c_we) begin
                            // write through, posted: the cache now, the SDRAM behind
                            dc_we <= 1'b1; dc_waddr <= A[15:4]; dc_wdata <= {1'b1, A[21:16], c_wd};
                            sd_req <= 1'b1; sd_addr <= 24'(RAM_W + {6'd0, A[21:4]});
                            sd_we <= 1'b1; sd_wdata <= c_wd; sd_be <= 2'b11;
                            posted <= 1'b1;
                            c_ack <= 1'b1; bst <= B_DONE;
                        end else bst <= B_DCK;
                    end
                    T_ROM: begin
                        // the cache is read on this clock; look at it on the next
                        bst <= c_we ? B_DONE : B_ICK;
                    end
                    T_GFX: begin
                        // midtunit_gfxrom_r: word o of the window, bank (o >> 21) & 1
                        // at 4 MB, then (o & 0x1fffff); 8 MB of ROM, nothing past it
                        sd_req <= !c_we; sd_addr <= 24'(GFX_W + {2'd0, 22'(A[26:4] - 23'h200000)});
                        sd_we <= 1'b0; sd_be <= 2'b11;
                        if (c_we) bst <= B_DONE;
                    end
                    T_CMOS: cmos_we <= c_we;
                    T_BLIT: blit_we <= c_we;
                    T_IO:   vreg_we <= c_we;
                    T_PAL:  pal_we  <= c_we;
                    T_CTRL: if (c_we) ctrl <= c_wd;
                    T_SND:  if (c_we && A[4]) begin
                                // offset 1 only; offset 0 is ignored (sound_w)
                                snd_reset  <= ~c_wd[8];
                                snd_cmd    <= c_wd[7:0];
                                snd_strobe <= 1'b1;
                                snd_fake   <= 8'd128;
                            end
                    T_PROT: if (c_we) begin
                                pq[0] <= c_wd;
                                pq[1] <= {prot_val[30:24], 9'd0};
                                pq[2] <= {prot_val[22:16], 9'd0};
                                pq[3] <= {prot_val[14:8],  9'd0};
                                pq[4] <= {prot_val[6:0],   9'd0};
                                pq_i  <= 3'd0;
                            end
                    default: ;
                endcase
            end
            B_WAIT: begin
                case (tl)
                    T_VRAM: if (sd_ack) begin
                        if (!sd_addr[1]) begin
                            // pixel 2o done; now 2o+1
                            vr_lo    <= sd_q;
                            sd_addr  <= sd_addr + 24'd1;
                            sd_wdata <= bank ? {blit_pal[15:8], c_wd[15:8]} : {c_wd[15:8], 8'h00};
                        end else begin
                            sd_req <= 1'b0;
                            c_rd   <= bank ? {sd_q[7:0], vr_lo[7:0]} : {sd_q[15:8], vr_lo[15:8]};
                            c_ack  <= 1'b1; bst <= B_DONE;
                        end
                    end
                    T_RAM, T_ROM, T_GFX:
                        if (sd_ack) begin
                            sd_req <= 1'b0; c_rd <= sd_q; c_ack <= 1'b1; bst <= B_DONE;
                            if (tl == T_ROM) begin
                                ic_we <= 1'b1; ic_waddr <= A[15:4]; ic_wdata <= {1'b1, A[22:16], sd_q};
                            end
                            if (tl == T_RAM) begin
                                dc_we <= 1'b1; dc_waddr <= A[15:4]; dc_wdata <= {1'b1, A[21:16], sd_q};
                            end
                        end
                    T_CMOS, T_PAL: begin
                        // the RAMs answer a clock after the address
                        pal_wait <= pal_wait + 2'd1;
                        if (pal_wait == 2'd1) begin
                            c_rd <= (tl == T_CMOS) ? cmos_q : pal_q;
                            c_ack <= 1'b1; bst <= B_DONE;
                        end
                    end
                    T_BLIT:  begin c_rd <= blit_q; c_ack <= 1'b1; bst <= B_DONE; end
                    T_IO:    begin c_rd <= vreg_q; c_ack <= 1'b1; bst <= B_DONE; end
                    T_IN:    begin
                        case (A[5:4])
                            2'd0: c_rd <= in0;
                            2'd1: c_rd <= in1;
                            2'd2: c_rd <= in2;
                            default: c_rd <= dsw;
                        endcase
                        c_ack <= 1'b1; bst <= B_DONE;
                    end
                    T_SSTAT: begin
                        // MAME fakes it: 0 for 128 reads after a command, then all ones
                        if (!c_we && snd_fake != 8'd0) begin c_rd <= 16'h0000; snd_fake <= snd_fake - 8'd1; end
                        else c_rd <= 16'hffff;
                        c_ack <= 1'b1; bst <= B_DONE;
                    end
                    T_PROT: begin
                        c_rd <= pq[pq_i];
                        if (!c_we && pq_i < 3'd4) pq_i <= pq_i + 3'd1;
                        c_ack <= 1'b1; bst <= B_DONE;
                    end
                    T_SND:   begin c_rd <= 16'hffff; c_ack <= 1'b1; bst <= B_DONE; end
                    default: begin c_rd <= 16'hffff; c_ack <= 1'b1; bst <= B_DONE; end
                endcase
            end
            B_ICK: begin
                if (ic_hit) begin c_rd <= ic_q[15:0]; c_ack <= 1'b1; bst <= B_DONE; end
                else if (!posted) begin
                    sd_req <= 1'b1; sd_addr <= 24'(PROG_W + {5'd0, A[22:4]});
                    sd_we <= 1'b0; sd_be <= 2'b11; bst <= B_WAIT;
                end
            end
            B_DCK: begin
                if (dc_hit) begin c_rd <= dc_q[15:0]; c_ack <= 1'b1; bst <= B_DONE; end
                else if (!posted) begin
                    sd_req <= 1'b1; sd_addr <= 24'(RAM_W + {6'd0, A[21:4]});
                    sd_we <= 1'b0; sd_be <= 2'b11; bst <= B_WAIT;
                end
            end
            B_SRT: if (srs == SR_DONE) begin
                c_rd <= sr_q_first; c_ack <= 1'b1; bst <= B_DONE;
            end
            // the CPU drops its request the clock after it sees the ack
            default: if (!c_req) bst <= B_IDLE;
        endcase
    end

    // a read transfer returns the register's first pixel (read_pixel_shiftreg)
    logic [15:0] sr_q_first;
    always_ff @(posedge clk)
        if (sr_we && sr_waddr == 10'd0) sr_q_first <= b_data;

    // ------------------------------------------------------------ protection table
    function automatic logic [31:0] nbajamte_prot(input logic [6:0] i);
        // nbajamte_prot_values, midtunit_m.cpp (all 128 entries distinct)
        case (i)
            7'd0:  return 32'h00000000; 7'd1:  return 32'h04081020; 7'd2:  return 32'h08102000; 7'd3:  return 32'h0c183122;
            7'd4:  return 32'h10200000; 7'd5:  return 32'h14281020; 7'd6:  return 32'h18312204; 7'd7:  return 32'h1c393326;
            7'd8:  return 32'h20000001; 7'd9:  return 32'h24081021; 7'd10: return 32'h28102000; 7'd11: return 32'h2c183122;
            7'd12: return 32'h30200001; 7'd13: return 32'h34281021; 7'd14: return 32'h38312204; 7'd15: return 32'h3c393326;
            7'd16: return 32'h00000102; 7'd17: return 32'h04081122; 7'd18: return 32'h08102102; 7'd19: return 32'h0c183122;
            7'd20: return 32'h10200000; 7'd21: return 32'h14281020; 7'd22: return 32'h18312204; 7'd23: return 32'h1c393326;
            7'd24: return 32'h20000103; 7'd25: return 32'h24081123; 7'd26: return 32'h28102102; 7'd27: return 32'h2c183122;
            7'd28: return 32'h30200001; 7'd29: return 32'h34281021; 7'd30: return 32'h38312204; 7'd31: return 32'h3c393326;
            7'd32: return 32'h00010204; 7'd33: return 32'h04091224; 7'd34: return 32'h08112204; 7'd35: return 32'h0c193326;
            7'd36: return 32'h10210204; 7'd37: return 32'h14291224; 7'd38: return 32'h18312204; 7'd39: return 32'h1c393326;
            7'd40: return 32'h20000001; 7'd41: return 32'h24081021; 7'd42: return 32'h28102000; 7'd43: return 32'h2c183122;
            7'd44: return 32'h30200001; 7'd45: return 32'h34281021; 7'd46: return 32'h38312204; 7'd47: return 32'h3c393326;
            7'd48: return 32'h00010306; 7'd49: return 32'h04091326; 7'd50: return 32'h08112306; 7'd51: return 32'h0c193326;
            7'd52: return 32'h10210204; 7'd53: return 32'h14291224; 7'd54: return 32'h18312204; 7'd55: return 32'h1c393326;
            7'd56: return 32'h20000103; 7'd57: return 32'h24081123; 7'd58: return 32'h28102102; 7'd59: return 32'h2c183122;
            7'd60: return 32'h30200001; 7'd61: return 32'h34281021; 7'd62: return 32'h38312204; 7'd63: return 32'h3c393326;
            7'd64: return 32'h00000000; 7'd65: return 32'h01201028; 7'd66: return 32'h02213018; 7'd67: return 32'h03012030;
            7'd68: return 32'h04223138; 7'd69: return 32'h05022110; 7'd70: return 32'h06030120; 7'd71: return 32'h07231108;
            7'd72: return 32'h08042231; 7'd73: return 32'h09243219; 7'd74: return 32'h0a251229; 7'd75: return 32'h0b050201;
            7'd76: return 32'h0c261309; 7'd77: return 32'h0d060321; 7'd78: return 32'h0e072311; 7'd79: return 32'h0f273339;
            7'd80: return 32'h10080422; 7'd81: return 32'h1128140a; 7'd82: return 32'h1229343a; 7'd83: return 32'h13092412;
            7'd84: return 32'h142a351a; 7'd85: return 32'h150a2532; 7'd86: return 32'h160b0502; 7'd87: return 32'h172b152a;
            7'd88: return 32'h180c2613; 7'd89: return 32'h192c363b; 7'd90: return 32'h1a2d160b; 7'd91: return 32'h1b0d0623;
            7'd92: return 32'h1c2e172b; 7'd93: return 32'h1d0e0703; 7'd94: return 32'h1e0f2733; 7'd95: return 32'h1f2f371b;
            7'd96: return 32'h20100804; 7'd97: return 32'h2130182c; 7'd98: return 32'h2231381c; 7'd99: return 32'h23112834;
            7'd100: return 32'h2432393c; 7'd101: return 32'h25122914; 7'd102: return 32'h26130924; 7'd103: return 32'h2733190c;
            7'd104: return 32'h28142a35; 7'd105: return 32'h29343a1d; 7'd106: return 32'h2a351a2d; 7'd107: return 32'h2b150a05;
            7'd108: return 32'h2c361b0d; 7'd109: return 32'h2d160b25; 7'd110: return 32'h2e172b15; 7'd111: return 32'h2f373b3d;
            7'd112: return 32'h30180c26; 7'd113: return 32'h31381c0e; 7'd114: return 32'h32393c3e; 7'd115: return 32'h33192c16;
            7'd116: return 32'h343a3d1e; 7'd117: return 32'h351a2d36; 7'd118: return 32'h361b0d06; 7'd119: return 32'h373b1d2e;
            7'd120: return 32'h381c2e17; 7'd121: return 32'h393c3e3f; 7'd122: return 32'h3a3d1e0f; 7'd123: return 32'h3b1d0e27;
            7'd124: return 32'h3c3e1f2f; 7'd125: return 32'h3d1e0f07; 7'd126: return 32'h3e1f2f37; default: return 32'h3f3f3f1f;
        endcase
    endfunction
    function automatic logic [31:0] nbajam_prot(input logic [6:0] i);
        // nbajam_prot_values, midtunit_m.cpp (entries 64-127 repeat 0-63)
        case (i[5:0])
            6'd0:  return 32'h21283b3b; 6'd1:  return 32'h2439383b; 6'd2:  return 32'h31283b3b; 6'd3:  return 32'h302b3938;
            6'd4:  return 32'h31283b3b; 6'd5:  return 32'h302b3938; 6'd6:  return 32'h232f2f2f; 6'd7:  return 32'h26383b3b;
            6'd8:  return 32'h21283b3b; 6'd9:  return 32'h2439383b; 6'd10: return 32'h312a1224; 6'd11: return 32'h302b1120;
            6'd12: return 32'h312a1224; 6'd13: return 32'h302b1120; 6'd14: return 32'h232d283b; 6'd15: return 32'h26383b3b;
            6'd16: return 32'h2b3b3b3b; 6'd17: return 32'h2e2e2e2e; 6'd18: return 32'h39383b1b; 6'd19: return 32'h383b3b1b;
            6'd20: return 32'h3b3b3b1b; 6'd21: return 32'h3a3a3a1a; 6'd22: return 32'h2b3b3b3b; 6'd23: return 32'h2e2e2e2e;
            6'd24: return 32'h2b39383b; 6'd25: return 32'h2e2e2e2e; 6'd26: return 32'h393a1a18; 6'd27: return 32'h383b1b1b;
            6'd28: return 32'h3b3b1b1b; 6'd29: return 32'h3a3a1a18; 6'd30: return 32'h2b39383b; 6'd31: return 32'h2e2e2e2e;
            6'd32: return 32'h01202b3b; 6'd33: return 32'h0431283b; 6'd34: return 32'h11202b3b; 6'd35: return 32'h1021283b;
            6'd36: return 32'h11202b3b; 6'd37: return 32'h1021283b; 6'd38: return 32'h03273b3b; 6'd39: return 32'h06302b39;
            6'd40: return 32'h09302b39; 6'd41: return 32'h0c232f2f; 6'd42: return 32'h19322e06; 6'd43: return 32'h18312a12;
            6'd44: return 32'h19322e06; 6'd45: return 32'h18312a12; 6'd46: return 32'h0b31283b; 6'd47: return 32'h0e26383b;
            6'd48: return 32'h03273b3b; 6'd49: return 32'h06302b39; 6'd50: return 32'h11202b3b; 6'd51: return 32'h1021283b;
            6'd52: return 32'h13273938; 6'd53: return 32'h12243938; 6'd54: return 32'h03273b3b; 6'd55: return 32'h06302b39;
            6'd56: return 32'h0b31283b; 6'd57: return 32'h0e26383b; 6'd58: return 32'h19322e06; 6'd59: return 32'h18312a12;
            6'd60: return 32'h1b332f05; 6'd61: return 32'h1a302b11; 6'd62: return 32'h0b31283b; default: return 32'h0e26383b;
        endcase
    endfunction

    wire _unused = &{1'b0, pen, env, c_rd[0]};
endmodule

`default_nettype wire
