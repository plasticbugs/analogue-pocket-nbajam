//------------------------------------------------------------------------------
// The Williams ADPCM sound board (docs/hardware.md section 6), from MAME's
// williams_adpcm_sound_device.  MC6809E at 2 MHz, YM2151 at 3.579545 MHz, an
// AD7524 DAC written by the 6809, and an OKI MSM6295 at 1 MHz.
//
// The clocking, the 6809's bus discipline and the YM2151's write timing are
// Smash TV's rtl/stv_sound.sv, which runs the same 6809 and YM2151 on a
// Pocket; read its comments for why.  What is this board's:
//
//   0000-1fff  RAM                      2c00  OKI6295
//   2000       ROM bank <- D2:0         3000  command latch (a read clears IRQ)
//   2400-2401  YM2151                   3400  OKI bank <- D2:0
//   2800       DAC                      3c00  talkback (write only, nowhere)
//   4000-bfff  banked ROM: u3[(bank & 3) * 0x8000 + (a - 0x4000)]
//   c000-ffff  fixed ROM:  u3[0x1c000 + (a - 0xc000)]
//   fbaa-fbd4  43 bytes of RAM over the ROM (init_nbajam's hidden RAM:
//              zero at power-up, kept across sound resets)
//
// IRQ is the command latch (set by a main-board write, cleared by the read
// at 3000); FIRQ is the YM2151.  Bit 8 low in the main board's write holds
// the board in reset, which also puts the ROM bank back to 0.
//
// ROMs: the 6809's u3 from the Pocket's SRAM (a private port, fixed
// latency, METHODOLOGY 5.3); the OKI's 1 MB from SDRAM.
//------------------------------------------------------------------------------
`default_nettype none

module tunit_sound (
    input  logic        clk,          // 96 MHz
    input  logic        rst,          // power-up
    input  logic        pause,

    // the main board's write to 01d0_1030 (docs/hardware.md 5)
    input  logic  [7:0] cmd,
    input  logic        cmd_strobe,
    input  logic        cmd_reset,    // level: hold the board in reset

    // 6809 ROM: u3, byte address
    output logic [16:0] rom_addr,
    output logic        rom_req,
    input  logic  [7:0] rom_q,
    input  logic        rom_ack,

    // OKI ROM: byte address into the 1 MB region
    output logic [19:0] oki_addr,
    output logic        oki_req,
    input  logic  [7:0] oki_q,
    input  logic        oki_ack,

    output logic signed [15:0] snd,
    output logic [15:0] stalls,
    output logic [15:0] dbg_pc
);
    wire reset = rst | cmd_reset;

    localparam int SETTLE = 5;
    localparam logic [5:0] SAMPLE = 6'd10;

    // ---------------- clocking (Smash TV's) ----------------
    logic [5:0] phase;
    wire        e_clk = (phase >= 6'd24);
    wire        q_clk = (phase >= 6'd12) && (phase < 6'd36);
    logic       rom_done;
    logic [7:0] rom_l;
    logic [2:0] rom_age;
    logic       rom_want;
    wire rom_wait = rom_want && (rom_age != 3'(SETTLE));
    wire last     = (phase == 6'd47);
    logic       ym_wr_pend, ym_wr_act;
    wire        cpu_rnw;
    wire [15:0] cpu_addr;
    wire sel_ym   = (cpu_addr[15:10] == 6'b0010_01);           // 2400
    wire ym_wait  = sel_ym && !cpu_rnw && (ym_wr_pend || ym_wr_act);
    wire stall    = last && (rom_wait || ym_wait);

    always_ff @(posedge clk)
        if (rst) phase <= 6'd0;
        else if (!pause && !stall) phase <= last ? 6'd0 : phase + 1'd1;

    wire cen_e  = last && !stall && !pause;
    wire cen_q  = (phase == 6'd35) && !pause;
    wire wr_now = cen_e && !cpu_rnw;

    logic stall_q;
    always_ff @(posedge clk) begin
        stall_q <= stall;
        if (rst) stalls <= '0;
        else if (stall && !stall_q && !(&stalls)) stalls <= stalls + 1'd1;
    end

    // YM2151: 2^24 * 3.579545 / 96 = 625571.6
    logic [24:0] ym_acc;
    logic        ym_half, ym_cen, ym_cen_p1;
    always_ff @(posedge clk) begin
        ym_cen    <= 1'b0;
        ym_cen_p1 <= 1'b0;
        if (rst) begin
            ym_acc <= '0; ym_half <= 1'b0;
        end else if (!pause) begin
            ym_acc <= {1'b0, ym_acc[23:0]} + 25'd625572;
            if (ym_acc[24]) begin
                ym_cen  <= 1'b1;
                ym_half <= ~ym_half;
                if (ym_half) ym_cen_p1 <= 1'b1;
            end
        end
    end
    // OKI: 1 MHz = 96 / 96
    logic [6:0] oki_div;
    wire        cen_oki = (oki_div == 7'd95) && !pause;
    always_ff @(posedge clk)
        if (rst) oki_div <= '0;
        else if (!pause) oki_div <= (oki_div == 7'd95) ? 7'd0 : oki_div + 7'd1;

    // ---------------- CPU ----------------
    wire  [7:0] cpu_dout;
    wire        cpu_avma;
    /* verilator lint_off UNOPTFLAT */
    logic [7:0] cpu_din;
    /* verilator lint_on UNOPTFLAT */
    logic [7:0] din_r;
    logic       irq_cmd;              // the command latch's IRQ
    logic       ym_irq_n_s;

    mc6809e cpu (
        .D(din_r), .DOut(cpu_dout), .ADDR(cpu_addr), .RnW(cpu_rnw),
        .E(e_clk), .Q(q_clk), .BS(), .BA(),
        .clk(clk), .cen_e(cen_e), .cen_q(cen_q),
        .nIRQ(~irq_cmd), .nFIRQ(ym_irq_n_s), .nNMI(1'b1),
        .AVMA(cpu_avma), .BUSY(), .LIC(), .nHALT(1'b1), .nRESET(~reset)
    );
    assign dbg_pc = cpu_addr;

    // ---------------- decode ----------------
    wire sel_ram  = (cpu_addr[15:13] == 3'b000);
    wire sel_bank = (cpu_addr[15:10] == 6'b0010_00);           // 2000
    wire sel_dac  = (cpu_addr[15:10] == 6'b0010_10);           // 2800
    wire sel_oki  = (cpu_addr[15:10] == 6'b0010_11);           // 2c00
    wire sel_cmd  = (cpu_addr[15:10] == 6'b0011_00);           // 3000
    wire sel_okb  = (cpu_addr[15:10] == 6'b0011_01);           // 3400
    wire sel_rom  = cpu_addr[15] || cpu_addr[14];              // 4000-ffff
    wire sel_hid  = (cpu_addr >= 16'hfbaa) && (cpu_addr <= 16'hfbd4);

    // ---------------- RAM, 8 KB ----------------
    logic [7:0] ram [0:8191];
    logic [7:0] ram_q;
    always_ff @(posedge clk) begin
        if (sel_ram && wr_now) ram[cpu_addr[12:0]] <= cpu_dout;
        ram_q <= ram[cpu_addr[12:0]];
    end

    // ---------------- the hidden RAM ----------------
    logic [7:0] hid [0:63];
    logic [7:0] hid_q;
    wire  [5:0] hid_a = 6'(cpu_addr - 16'hfbaa);
    logic [63:0] hid_set;                // written since power-up (zero before)
    always_ff @(posedge clk) begin
        if (sel_hid && wr_now) begin hid[hid_a] <= cpu_dout; hid_set[hid_a] <= 1'b1; end
        hid_q <= hid_set[hid_a] ? hid[hid_a] : 8'h00;
        if (rst) hid_set <= '0;
    end

    // ---------------- banked ROM ----------------
    logic [2:0] bank;
    always_ff @(posedge clk) begin
        if (reset) bank <= 3'd0;
        else if (sel_bank && wr_now) bank <= cpu_dout[2:0];
    end
    assign rom_addr = cpu_addr[15:14] == 2'b11 ? {3'b111, cpu_addr[13:0]}       // 1c000 + (a - c000)
                                               : {bank[1:0], 15'(cpu_addr - 16'h4000)};
    logic vma;
    always_ff @(posedge clk) begin
        if (rst) vma <= 1'b1;
        else if (cen_e) vma <= cpu_avma;
    end
    wire dead = !vma && (cpu_addr == 16'hffff);
    assign rom_want = sel_rom && !sel_hid && cpu_rnw && !reset && !dead && (phase >= 6'(SETTLE));
    assign rom_req  = rom_want && !rom_done;
    always_ff @(posedge clk) begin
        if (rst || cen_e) rom_done <= 1'b0;
        else if (rom_req && rom_ack) begin rom_done <= 1'b1; rom_l <= rom_q; end
    end
    always_ff @(posedge clk) begin
        if (rst || cen_e || !rom_done) rom_age <= 3'd0;
        else if (rom_age != 3'(SETTLE)) rom_age <= rom_age + 3'd1;
    end

    // ---------------- the command latch ----------------
    // MAME: the write sets the latch and IRQ at once (sync_command); the read
    // at 3000 clears IRQ.  The latch is not cleared by a sound reset.
    logic [7:0] latch, latch_s;
    always_ff @(posedge clk) begin
        if (rst) begin latch <= 8'h00; irq_cmd <= 1'b0; end
        else begin
            if (sel_cmd && cpu_rnw && cen_e) irq_cmd <= 1'b0;
            if (cmd_reset) irq_cmd <= 1'b0;                       // device_reset
            if (cmd_strobe) begin latch <= cmd; irq_cmd <= 1'b1; end
        end
    end

    // ---------------- YM2151 (Smash TV's write timing) ----------------
    logic       ym_rst;
    logic [7:0] ym_din_l, ym_dout, ym_dout_s;
    logic       ym_a0_l, ym_irq_n;
    always_ff @(posedge clk) begin
        ym_rst <= reset;
        if (reset) begin ym_wr_pend <= 1'b0; ym_wr_act <= 1'b0; end
        else begin
            if (ym_cen_p1) begin
                if (ym_wr_act)       ym_wr_act <= 1'b0;
                else if (ym_wr_pend) begin ym_wr_act <= 1'b1; ym_wr_pend <= 1'b0; end
            end
            if (sel_ym && wr_now) begin
                ym_wr_pend <= 1'b1;
                ym_din_l   <= cpu_dout;
                ym_a0_l    <= cpu_addr[0];
            end
        end
    end
    wire signed [15:0] ym_left, ym_right;
    jt51 ym (
        .rst(ym_rst), .clk(clk), .cen(ym_cen), .cen_p1(ym_cen_p1),
        .cs_n(~(ym_wr_act | (sel_ym & cpu_rnw & (phase >= 6'(SETTLE))))),
        .wr_n(~ym_wr_act),
        .a0(ym_wr_act ? ym_a0_l : cpu_addr[0]),
        .din(ym_din_l), .dout(ym_dout),
        .ct1(), .ct2(), .irq_n(ym_irq_n), .sample(),
        .left(ym_left), .right(ym_right), .xleft(), .xright()
    );

    // ---------------- DAC ----------------
    logic [7:0] dac;
    always_ff @(posedge clk)
        if (rst) dac <= 8'h80;
        else if (sel_dac && wr_now) dac <= cpu_dout;

    // ---------------- OKI6295 ----------------
    // The chip's 256 KB space: 00000-1ffff is the bank, 20000-3ffff region
    // 0x60000.  Banks (region offsets): 0,1 -> 40000, 2 -> 20000, 3 -> 00000,
    // 4 -> e0000, 5 -> c0000, 6 -> a0000, 7 -> 80000.
    // MAME's reset_write puts the ROM bank back to 0 and leaves this alone
    logic [2:0] okbank_q;
    always_ff @(posedge clk)
        if (rst) okbank_q <= 3'd0;
        else if (sel_okb && wr_now) okbank_q <= cpu_dout[2:0];

    function automatic logic [2:0] okb_base(input logic [2:0] b);   // region offset >> 17
        case (b)
            3'd0, 3'd1: return 3'd2;
            3'd2:       return 3'd1;
            3'd3:       return 3'd0;
            3'd4:       return 3'd7;
            3'd5:       return 3'd6;
            3'd6:       return 3'd5;
            default:    return 3'd4;
        endcase
    endfunction

    logic        oki_wr_p;
    logic  [7:0] oki_d_p, oki_dout, oki_dout_s;
    wire  [17:0] oki_rom_addr;
    logic  [7:0] oki_rom_data;
    logic        oki_rom_ok;
    wire signed [13:0] oki_snd;
    // a write is held for a whole OKI clock so jt6295 cannot miss it
    logic  [6:0] oki_hold;
    always_ff @(posedge clk) begin
        if (rst) begin oki_wr_p <= 1'b0; oki_hold <= '0; end
        else begin
            if (sel_oki && wr_now) begin oki_wr_p <= 1'b1; oki_d_p <= cpu_dout; oki_hold <= 7'd100; end
            else if (oki_hold != 7'd0) oki_hold <= oki_hold - 7'd1;
            else oki_wr_p <= 1'b0;
        end
    end
    jt6295 #(.INTERPOL(0), .SAMPLE(0)) u_oki (
        .rst(rst), .clk(clk), .cen(cen_oki), .ss(1'b1),
        .wrn(~oki_wr_p), .din(oki_d_p), .dout(oki_dout),
        .rom_addr(oki_rom_addr), .rom_data(oki_rom_data), .rom_ok(oki_rom_ok),
        .sound(oki_snd), .sample()
    );
    wire [19:0] oki_region = oki_rom_addr[17] ? {3'b011, oki_rom_addr[16:0]}          // 60000 + (a - 20000)
                                              : {okb_base(okbank_q), oki_rom_addr[16:0]};
    // ROM handshake (STUN Runner's): rom_ok drops for a new address, rises with its byte
    logic [17:0] oki_cur;
    always_ff @(posedge clk) begin
        if (rst) begin
            oki_req <= 1'b0; oki_rom_ok <= 1'b0; oki_cur <= '0; oki_addr <= '0; oki_rom_data <= 8'h00;
        end else if (oki_req) begin
            if (oki_ack) begin oki_req <= 1'b0; oki_rom_data <= oki_q; oki_rom_ok <= 1'b1; end
        end else if (oki_rom_addr != oki_cur || !oki_rom_ok) begin
            oki_cur <= oki_rom_addr; oki_addr <= oki_region; oki_req <= 1'b1; oki_rom_ok <= 1'b0;
        end
    end

    // ---------------- what the 6809 reads, held still ----------------
    always_ff @(posedge clk) begin
        if (phase == SAMPLE) begin
            ym_dout_s  <= ym_dout; oki_dout_s <= oki_dout;
            latch_s    <= latch;   ym_irq_n_s <= ym_irq_n;
        end
        din_r <= cpu_din;
    end
    always_comb begin
        cpu_din = 8'hff;
        if      (sel_ram) cpu_din = ram_q;
        else if (sel_ym)  cpu_din = ym_dout_s;
        else if (sel_oki) cpu_din = oki_dout_s;
        else if (sel_cmd) cpu_din = latch_s;
        else if (sel_hid) cpu_din = hid_q;
        else if (sel_rom) cpu_din = rom_l;
    end

    // ---------------- mixer ----------------
    // MAME's routes: YM2151 both channels x0.10, DAC x0.10, OKI x0.15, each at
    // a 16-bit full scale.  In 1/4096: 410, 410, 614.  To be checked against a
    // MAME recording by band energy (CLAUDE.md step 8) before it is trusted.
    wire signed [15:0] dac_s = {~dac[7], dac[6:0], 8'h00};
    wire signed [15:0] oki_s = {oki_snd, 2'b00};
    logic signed [15:0] m_yl, m_yr, m_dac, m_oki;
    logic signed [31:0] p_ym, p_dac, p_oki, m_sum;
    wire  signed [16:0] m_ysum = {m_yl[15], m_yl} + {m_yr[15], m_yr};
    wire  signed [19:0] mix_s  = m_sum[31:12];
    always_ff @(posedge clk) begin
        m_yl <= ym_left; m_yr <= ym_right; m_dac <= dac_s; m_oki <= oki_s;
        p_ym  <= 32'sd410 * m_ysum;
        p_dac <= 32'sd410 * m_dac;
        p_oki <= 32'sd614 * m_oki;
        m_sum <= p_ym + p_dac + p_oki;
        snd   <= (mix_s >  20'sd32767) ?  16'sd32767 :
                 (mix_s < -20'sd32768) ? 16'sh8000 : mix_s[15:0];
    end

endmodule

`default_nettype wire
