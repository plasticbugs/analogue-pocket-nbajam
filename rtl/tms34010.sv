//------------------------------------------------------------------------------
// TMS34010 graphics system processor, written against MAME 0.288's
// (ref/mame/devices/cpu/tms34010/) and held to it one instruction and one bus
// transaction at a time by sim/run_cpu.sh.
//
// What it is: 31 32-bit registers (A0-A14, B0-B14 and a shared SP), a 32-bit
// bit-addressed program counter, a status register that carries two field
// definitions, and memory that is only ever reached as *fields* of 1 to 32
// bits at any bit address.  The bus underneath is 16-bit words.
//
// How it is built: a plain multi-cycle machine.  Fetch the opcode, fetch its
// extension words, execute; anything that touches memory goes through one
// field engine, which turns (bit address, size, read or write) into the same
// sequence of word transactions MAME makes -- including MAME's habit of
// reading four words for a misaligned 32-bit field where three would do,
// because the bench compares bus traces and a fourth read is harmless.  An
// instruction then waits out the rest of its cycle count on `cen`, so the
// program runs at the board's speed and not the memory's.
//
// What follows MAME rather than the data book, on purpose, because MAME is
// what the game is known to run on and what the traces come from:
//   * ADDC and SUBB compute carry and overflow without the carry-in;
//   * a conditional jump that is not taken does not fetch its operand;
//   * CALLR and CALLA push before they fetch their operand;
//   * interrupts are looked for between instructions (MAME looks less often,
//     at timeslice boundaries, which is an emulator's economy, not the chip).
//
// What is not here, and raises `unimpl` rather than doing something plausible:
// LINE, the four pixel-array PIXBLTs, raster ops, window checking, plane
// masking, 32-bit pixels in PIXBLT B and FILL, the host interface.
// docs/hardware.md section 9 has the measurement that this game executes none
// of them.  PIXBLT B and FILL run to completion in one go; MAME's P flag and
// its re-execution of the instruction to burn cycles are an emulator's
// bookkeeping, and the bench steps over them.
//------------------------------------------------------------------------------
`default_nettype none

module tms34010 #(
    // The bench answers every read from MAME's own bus trace, including reads
    // of the interrupt-pending register, so that a program polling it sees
    // what MAME's did.  In the machine the CPU answers those itself.
    parameter bit IO_READ_FROM_BUS = 1'b0,
    // The state machine below advances on one clock in STEP.  Its execute
    // state goes from the instruction register through the register file and
    // the ALU, the shifter or the divider and back into the register file,
    // which is about 19.5 ns of logic in this part (measured: -9.1 ns of
    // slack at 96 MHz with STEP 1).  Nothing needs it to be faster - the
    // pacing below makes the CPU wait out most of its clocks anyway - so
    // every register of the machine proper is enabled by `step`, and the SDC
    // gives the paths among them STEP clocks.  What must see every clock -
    // the bus handshake, the display interrupt's pulse, the cycle account -
    // is in the small every-clock block at the end, and is NOT in that
    // constraint.  projects/smashtv_pocket.sdc has the register lists; keep
    // them in step with the two blocks.
    parameter int STEP = 3
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen,            // one pulse per machine cycle, 5 MHz

    // ---------------- the local bus: 16-bit words at bit addresses
    output logic        bus_req,
    output logic        bus_we,
    output logic [31:4] bus_addr,
    output logic [15:0] bus_wdata,
    input  logic [15:0] bus_rdata,
    input  logic        bus_ack,
    // This access is a VRAM shift-register transfer, not a data access:
    // DPYCTL's SRT bit is set and the instruction is a pixel operation, a
    // FILL or a PIXBLT (MAME's shiftreg_r/_w).  A read loads the shift
    // register from the row at bus_addr; a write stores it there.  NBA Jam
    // (this core's copy, from Smash TV's) clears a page every frame with a
    // FILL through the shift register (docs/hardware.md 7.4).
    output logic        bus_srt,

    // ---------------- interrupts
    input  logic        int1,           // level
    input  logic        int2,           // level
    input  logic        dpyint,         // pulse: VCOUNT == DPYINT

    // ---------------- for the bench and the bring-up panel
    output logic        insn_start,     // pulse as each opcode fetch begins
    output logic        irq_taken,      // pulse as an interrupt is entered
    output logic [31:0] dbg_pc,
    output logic        unimpl          // sticky: met something not built
);
    // The reset, registered here.  It reaches every register below and the
    // DSP block's input registers, and from core_top's one register that was
    // a long wire (-0.3 ns in the sixth compile).  It is held for thousands of
    // clocks, so a clock more is nothing.
    logic rst_q;
    always_ff @(posedge clk) rst_q <= rst;

    // ---- stepping (see STEP above)
    // A step needs STEP clocks since the last one - that is all the SDC's
    // three-clock paths rely on - and, while a bus request is out, the ack:
    // the machine does nothing but wait for it, so rather than look every
    // third clock it steps the clock after the ack is in.
    logic  [1:0] stepcnt;
    logic        q_req;                         // the machine's request
    logic        q_ack;                         // an ack it has not seen yet
    wire         step  = (stepcnt == 2'(STEP - 1)) && !(q_req && !q_ack);
    wire         first = (stepcnt == 2'd0);     // the clock after a step
    logic [15:0] q_rdata;
    logic        dpy_l;                         // a display interrupt it has not seen yet
    logic        insn_start_q, irq_taken_q;

    // ------------------------------------------------------------ state
    logic [31:0] ra [15];   // A0..A14
    logic [31:0] rb [15];   // B0..B14
    logic [31:0] sp;
    logic [31:0] pc;
    logic [31:0] st;
    assign dbg_pc = pc;

    localparam int ST_N = 31, ST_C = 30, ST_Z = 29, ST_V = 28, ST_IE = 21;

    // I/O registers the CPU itself needs; the rest live outside and are
    // reached over the bus like any other memory.
    logic [15:0] io_control;
    logic [15:0] io_convsp;
    logic [15:0] io_convdp;
    logic [15:0] io_psize;
    logic [15:0] io_pmask;
    logic [15:0] io_intenb;
    logic        io_srt;   // DPYCTL bit 11
    logic [15:0] io_intpend;
    localparam logic [4:0] IO_CONTROL = 5'h0b, IO_INTENB = 5'h11, IO_INTPEND = 5'h12,
                           IO_CONVSP = 5'h13, IO_CONVDP = 5'h14, IO_PSIZE = 5'h15,
                           IO_PMASK = 5'h16, IO_DPYCTL = 5'h08;

    // ------------------------------------------------------------ helpers
    function automatic logic [31:0] rget(input logic file, input logic [3:0] i);
        if (i == 4'd15) return sp;
        return file ? rb[i] : ra[i];
    endfunction

    function automatic logic [5:0] fsize(input logic [4:0] fs);  // 0 means 32
        return (fs == 5'd0) ? 6'd32 : {1'b0, fs};
    endfunction

    function automatic logic [31:0] fmask(input logic [5:0] size);
        return (size >= 6'd32) ? 32'hffff_ffff : ((32'd1 << size) - 32'd1);
    endfunction

    function automatic logic [31:0] sext_n(input logic [31:0] v, input logic [5:0] size);
        logic [31:0] m;
        m = fmask(size);
        if (size >= 6'd32) return v;
        return v[size - 1] ? (v | ~m) : (v & m);
    endfunction

    // ------------------------------------------------------------ decode
    logic [15:0] ir;
    wire         fR  = ir[4];
    wire   [3:0] rs  = ir[8:5];
    wire   [3:0] rd  = ir[3:0];
    wire   [4:0] kf  = ir[9:5];

    typedef enum logic [6:0] {
        K_UNIMPL, K_ILLOP, K_NOP,
        K_REV, K_EXGPC, K_GETPC, K_JUMP, K_GETST, K_PUTST, K_POPST, K_PUSHST,
        K_CLRC, K_SETC, K_DINT, K_EINT,
        K_ABS, K_NEG, K_NEGB, K_NOT,
        K_SEXT, K_ZEXT, K_SETF, K_EXGF,
        K_TRAP, K_CALL, K_CALLR, K_CALLA, K_RETI, K_RETS,
        K_MMTM, K_MMFM,
        K_MOVI, K_ADDI, K_CMPI, K_ANDI, K_ORI, K_XORI, K_SUBI,
        K_DSJ, K_DSJEQ, K_DSJNE, K_DSJS,
        K_ADDK, K_SUBK, K_MOVK, K_BTSTK,
        K_SLA, K_SLL, K_SRA, K_SRL, K_RL,
        K_ADD, K_ADDC, K_SUB, K_SUBB, K_CMP, K_BTSTR, K_MOVERR,
        K_AND, K_ANDN, K_OR, K_XOR,
        K_DIVS, K_DIVU, K_MPYS, K_MPYU, K_LMO, K_MODS, K_MODU,
        K_MOVE,
        K_JCC,
        K_ADDXY, K_SUBXY, K_CMPXY, K_CPW, K_CVXYL, K_MOVX, K_MOVY,
        K_PIXT, K_DRAV, K_GFX
    } kind_t;

    // addressing modes of a MOVE or MOVB operand
    typedef enum logic [2:0] { AM_REG, AM_IND, AM_PI, AM_PD, AM_OFF, AM_ABS } am_t;

    kind_t       kind;
    am_t         m_src, m_dst;
    logic  [1:0] m_fld;                 // 0 field 0, 1 field 1, 2 byte
    logic  [3:0] m_dreg;                // the register holding the data (R->mem)
    logic  [2:0] next;                  // extension words to fetch
    logic        lng;                   // immediate is a long
    logic  [1:0] fsel;                  // which field, for SEXT/ZEXT/SETF/EXGF
    logic        shr;                   // shift amount from a register
    logic  [2:0] pixt_m;                // which PIXT form
    logic  [5:0] cyc;                   // MAME's cycle count

    always_comb begin
        kind = K_UNIMPL; m_src = AM_REG; m_dst = AM_REG; m_fld = 2'd0;
        m_dreg = rs; next = 3'd0; lng = 1'b0; fsel = 2'd0; shr = 1'b0;
        pixt_m = 3'd0; cyc = 6'd1;
        casez (ir)
            // ---- 0x0000 .. 0x0fff
            16'b0000_0000_001?_????: begin kind = K_REV; end
            16'b0000_0001_0000_????: begin kind = K_NOP;   cyc = 6'd6; end   // EMU
            16'b0000_0001_001?_????: begin kind = K_EXGPC; cyc = 6'd2; end
            16'b0000_0001_010?_????: begin kind = K_GETPC; end
            16'b0000_0001_011?_????: begin kind = K_JUMP;  cyc = 6'd2; end
            16'b0000_0001_100?_????: begin kind = K_GETST; end
            16'b0000_0001_101?_????: begin kind = K_PUTST; cyc = 6'd3; end
            16'b0000_0001_1100_????: begin kind = K_POPST; cyc = 6'd8; end
            16'b0000_0001_1110_????: begin kind = K_PUSHST; cyc = 6'd2; end
            16'b0000_0010_????_????: begin kind = K_ILLOP; cyc = 6'd16; end
            16'b0000_0011_0000_????: begin kind = K_NOP; end
            16'b0000_0011_0010_????: begin kind = K_CLRC; end
            16'b0000_0011_0100_????: begin kind = K_MOVE; m_src = AM_ABS; m_dst = AM_ABS;
                                           m_fld = 2'd2; next = 3'd4; cyc = 6'd6; end
            16'b0000_0011_0110_????: begin kind = K_DINT; cyc = 6'd3; end
            16'b0000_0011_100?_????: begin kind = K_ABS; end
            16'b0000_0011_101?_????: begin kind = K_NEG; end
            16'b0000_0011_110?_????: begin kind = K_NEGB; end
            16'b0000_0011_111?_????: begin kind = K_NOT; end
            16'b0000_0100_????_????: begin kind = K_ILLOP; cyc = 6'd16; end
            16'b0000_01?1_000?_????: begin kind = K_SEXT; fsel = {1'b0, ir[9]}; cyc = 6'd3; end
            16'b0000_01?1_001?_????: begin kind = K_ZEXT; fsel = {1'b0, ir[9]}; end
            16'b0000_01?1_01??_????: begin kind = K_SETF; fsel = {1'b0, ir[9]};
                                           cyc = ir[9] ? 6'd2 : 6'd1; end
            16'b0000_01?1_100?_????: begin kind = K_MOVE; m_dst = AM_ABS; m_dreg = rd;
                                           m_fld = {1'b0, ir[9]}; next = 3'd2; cyc = 6'd3; end
            16'b0000_01?1_101?_????: begin kind = K_MOVE; m_src = AM_ABS;
                                           m_fld = {1'b0, ir[9]}; next = 3'd2; cyc = 6'd5; end
            16'b0000_01?1_1100_????: begin kind = K_MOVE; m_src = AM_ABS; m_dst = AM_ABS;
                                           m_fld = {1'b0, ir[9]}; next = 3'd4; cyc = 6'd7; end
            16'b0000_0101_111?_????: begin kind = K_MOVE; m_dst = AM_ABS; m_dreg = rd;
                                           m_fld = 2'd2; next = 3'd2; cyc = 6'd1; end
            16'b0000_0111_111?_????: begin kind = K_MOVE; m_src = AM_ABS;
                                           m_fld = 2'd2; next = 3'd2; cyc = 6'd5; end
            16'b0000_1000_????_????: begin kind = K_ILLOP; cyc = 6'd16; end
            16'b0000_1001_000?_????: begin kind = K_TRAP;  cyc = 6'd16; end
            16'b0000_1001_001?_????: begin kind = K_CALL;  cyc = 6'd3; end
            16'b0000_1001_0100_????: begin kind = K_RETI;  cyc = 6'd11; end
            16'b0000_1001_011?_????: begin kind = K_RETS;  cyc = 6'd7; end
            16'b0000_1001_100?_????: begin kind = K_MMTM;  next = 3'd1; cyc = 6'd2; end
            16'b0000_1001_101?_????: begin kind = K_MMFM;  next = 3'd1; cyc = 6'd3; end
            16'b0000_1001_110?_????: begin kind = K_MOVI;  next = 3'd1; cyc = 6'd2; end
            16'b0000_1001_111?_????: begin kind = K_MOVI;  next = 3'd2; lng = 1'b1; cyc = 6'd3; end
            16'b0000_1010_????_????: begin kind = K_ILLOP; cyc = 6'd16; end
            16'b0000_1011_000?_????: begin kind = K_ADDI;  next = 3'd1; cyc = 6'd2; end
            16'b0000_1011_001?_????: begin kind = K_ADDI;  next = 3'd2; lng = 1'b1; cyc = 6'd3; end
            16'b0000_1011_010?_????: begin kind = K_CMPI;  next = 3'd1; cyc = 6'd2; end
            16'b0000_1011_011?_????: begin kind = K_CMPI;  next = 3'd2; lng = 1'b1; cyc = 6'd3; end
            16'b0000_1011_100?_????: begin kind = K_ANDI;  next = 3'd2; lng = 1'b1; cyc = 6'd3; end
            16'b0000_1011_101?_????: begin kind = K_ORI;   next = 3'd2; lng = 1'b1; cyc = 6'd3; end
            16'b0000_1011_110?_????: begin kind = K_XORI;  next = 3'd2; lng = 1'b1; cyc = 6'd3; end
            16'b0000_1011_111?_????: begin kind = K_SUBI;  next = 3'd1; cyc = 6'd2; end
            16'b0000_1100_????_????: begin kind = K_ILLOP; cyc = 6'd16; end
            16'b0000_1101_000?_????: begin kind = K_SUBI;  next = 3'd2; lng = 1'b1; cyc = 6'd3; end
            16'b0000_1101_0011_????: begin kind = K_CALLR; cyc = 6'd3; end
            16'b0000_1101_0101_????: begin kind = K_CALLA; cyc = 6'd4; end
            16'b0000_1101_0110_????: begin kind = K_EINT;  cyc = 6'd3; end
            16'b0000_1101_100?_????: begin kind = K_DSJ;   cyc = 6'd2; end
            16'b0000_1101_101?_????: begin kind = K_DSJEQ; cyc = 6'd2; end
            16'b0000_1101_110?_????: begin kind = K_DSJNE; cyc = 6'd2; end
            16'b0000_1101_1110_????: begin kind = K_SETC; end
            16'b0000_1110_????_????: begin kind = K_ILLOP; cyc = 6'd16; end
            // 0x0f80 PIXBLT B,L  0x0fa0 PIXBLT B,XY  0x0fc0 FILL L  0x0fe0 FILL XY
            // (the pixel-array-to-pixel-array PIXBLTs at 0x0f00-0x0f6f are
            // not built: measured, this game never executes one)
            16'b0000_1111_1??0_????: begin kind = K_GFX; cyc = 6'd0; end   // charged in G_INIT and per row

            // ---- 0x1000 .. 0x3fff: a 5-bit constant and a register
            16'b0001_00??_????_????: begin kind = K_ADDK; end
            16'b0001_01??_????_????: begin kind = K_SUBK; end
            16'b0001_10??_????_????: begin kind = K_MOVK; end
            16'b0001_11??_????_????: begin kind = K_BTSTK; end
            16'b0010_00??_????_????: begin kind = K_SLA; cyc = 6'd3; end
            16'b0010_01??_????_????: begin kind = K_SLL; end
            16'b0010_10??_????_????: begin kind = K_SRA; end
            16'b0010_11??_????_????: begin kind = K_SRL; end
            16'b0011_00??_????_????: begin kind = K_RL; end
            16'b0011_01??_????_????: begin kind = K_ILLOP; cyc = 6'd16; end
            16'b0011_1???_????_????: begin kind = K_DSJS; cyc = 6'd2; end

            // ---- 0x4000 .. 0x6fff: two registers
            16'b0100_000?_????_????: begin kind = K_ADD; end
            16'b0100_001?_????_????: begin kind = K_ADDC; end
            16'b0100_010?_????_????: begin kind = K_SUB; end
            16'b0100_011?_????_????: begin kind = K_SUBB; end
            16'b0100_100?_????_????: begin kind = K_CMP; end
            16'b0100_101?_????_????: begin kind = K_BTSTR; cyc = 6'd2; end
            16'b0100_11??_????_????: begin kind = K_MOVERR; end
            16'b0101_000?_????_????: begin kind = K_AND; end
            16'b0101_001?_????_????: begin kind = K_ANDN; end
            16'b0101_010?_????_????: begin kind = K_OR; end
            16'b0101_011?_????_????: begin kind = K_XOR; end
            16'b0101_100?_????_????: begin kind = K_DIVS; cyc = ir[0] ? 6'd39 : 6'd40; end   // 32-bit form (odd Rd) is 39
            16'b0101_101?_????_????: begin kind = K_DIVU; cyc = 6'd37; end
            16'b0101_110?_????_????: begin kind = K_MPYS; cyc = 6'd20; end
            16'b0101_111?_????_????: begin kind = K_MPYU; cyc = 6'd21; end
            16'b0110_000?_????_????: begin kind = K_SLA; shr = 1'b1; cyc = 6'd3; end
            16'b0110_001?_????_????: begin kind = K_SLL; shr = 1'b1; end
            16'b0110_010?_????_????: begin kind = K_SRA; shr = 1'b1; end
            16'b0110_011?_????_????: begin kind = K_SRL; shr = 1'b1; end
            16'b0110_100?_????_????: begin kind = K_RL;  shr = 1'b1; end
            16'b0110_101?_????_????: begin kind = K_LMO; end
            16'b0110_110?_????_????: begin kind = K_MODS; cyc = 6'd40; end
            16'b0110_111?_????_????: begin kind = K_MODU; cyc = 6'd35; end
            16'b0111_????_????_????: begin kind = K_ILLOP; cyc = 6'd16; end

            // ---- 0x8000 .. 0xbfff: MOVE and MOVB through registers
            16'b1000_00??_????_????: begin kind = K_MOVE; m_dst = AM_IND;
                                           m_fld = {1'b0, ir[9]}; cyc = 6'd1; end
            16'b1000_01??_????_????: begin kind = K_MOVE; m_src = AM_IND;
                                           m_fld = {1'b0, ir[9]}; cyc = 6'd3; end
            16'b1000_10??_????_????: begin kind = K_MOVE; m_src = AM_IND; m_dst = AM_IND;
                                           m_fld = {1'b0, ir[9]}; cyc = 6'd3; end
            16'b1000_110?_????_????: begin kind = K_MOVE; m_dst = AM_IND; m_fld = 2'd2; end
            16'b1000_111?_????_????: begin kind = K_MOVE; m_src = AM_IND; m_fld = 2'd2;
                                           cyc = 6'd3; end
            16'b1001_00??_????_????: begin kind = K_MOVE; m_dst = AM_PI;
                                           m_fld = {1'b0, ir[9]}; cyc = 6'd1; end
            16'b1001_01??_????_????: begin kind = K_MOVE; m_src = AM_PI;
                                           m_fld = {1'b0, ir[9]}; cyc = 6'd3; end
            16'b1001_10??_????_????: begin kind = K_MOVE; m_src = AM_PI; m_dst = AM_PI;
                                           m_fld = {1'b0, ir[9]}; cyc = 6'd4; end
            16'b1001_110?_????_????: begin kind = K_MOVE; m_src = AM_IND; m_dst = AM_IND;
                                           m_fld = 2'd2; cyc = 6'd3; end
            16'b1001_111?_????_????: begin kind = K_ILLOP; cyc = 6'd16; end
            16'b1010_00??_????_????: begin kind = K_MOVE; m_dst = AM_PD;
                                           m_fld = {1'b0, ir[9]}; cyc = 6'd2; end
            16'b1010_01??_????_????: begin kind = K_MOVE; m_src = AM_PD;
                                           m_fld = {1'b0, ir[9]}; cyc = 6'd4; end
            16'b1010_10??_????_????: begin kind = K_MOVE; m_src = AM_PD; m_dst = AM_PD;
                                           m_fld = {1'b0, ir[9]}; cyc = 6'd4; end
            16'b1010_110?_????_????: begin kind = K_MOVE; m_dst = AM_OFF; m_fld = 2'd2;
                                           next = 3'd1; cyc = 6'd3; end
            16'b1010_111?_????_????: begin kind = K_MOVE; m_src = AM_OFF; m_fld = 2'd2;
                                           next = 3'd1; cyc = 6'd5; end
            16'b1011_00??_????_????: begin kind = K_MOVE; m_dst = AM_OFF;
                                           m_fld = {1'b0, ir[9]}; next = 3'd1; cyc = 6'd3; end
            16'b1011_01??_????_????: begin kind = K_MOVE; m_src = AM_OFF;
                                           m_fld = {1'b0, ir[9]}; next = 3'd1; cyc = 6'd5; end
            16'b1011_10??_????_????: begin kind = K_MOVE; m_src = AM_OFF; m_dst = AM_OFF;
                                           m_fld = {1'b0, ir[9]}; next = 3'd2; cyc = 6'd5; end
            16'b1011_110?_????_????: begin kind = K_MOVE; m_src = AM_OFF; m_dst = AM_OFF;
                                           m_fld = 2'd2; next = 3'd2; cyc = 6'd5; end
            16'b1011_111?_????_????: begin kind = K_ILLOP; cyc = 6'd16; end

            // ---- 0xc000: the sixteen conditional jumps
            16'b1100_????_????_????: begin kind = K_JCC; end

            // ---- 0xd000
            16'b1101_00??_????_????: begin kind = K_MOVE; m_src = AM_OFF; m_dst = AM_PI;
                                           m_fld = {1'b0, ir[9]}; next = 3'd1; cyc = 6'd5; end
            16'b1101_01?0_000?_????: begin kind = K_MOVE; m_src = AM_ABS; m_dst = AM_PI;
                                           m_fld = {1'b0, ir[9]}; next = 3'd2; cyc = 6'd5; end
            16'b1101_01?1_000?_????: begin kind = K_EXGF; fsel = {1'b0, ir[9]}; end
            16'b1101_1???_????_????: begin kind = (ir[15:8] == 8'hdf) ? K_UNIMPL : K_ILLOP;
                                           cyc = 6'd16; end       // DFxx is LINE

            // ---- 0xe000 .. 0xffff: XY and pixel operations
            16'b1110_000?_????_????: begin kind = K_ADDXY; end
            16'b1110_001?_????_????: begin kind = K_SUBXY; end
            16'b1110_010?_????_????: begin kind = K_CMPXY; end
            16'b1110_011?_????_????: begin kind = K_CPW; end
            16'b1110_100?_????_????: begin kind = K_CVXYL; cyc = 6'd3; end
            16'b1110_110?_????_????: begin kind = K_MOVX; end
            16'b1110_111?_????_????: begin kind = K_MOVY; end
            16'b1111_000?_????_????: begin kind = K_PIXT; pixt_m = 3'd0; cyc = 6'd4; end // R,*R.XY
            16'b1111_001?_????_????: begin kind = K_PIXT; pixt_m = 3'd1; cyc = 6'd6; end // *R.XY,R
            16'b1111_010?_????_????: begin kind = K_PIXT; pixt_m = 3'd2; cyc = 6'd7; end // *R.XY,*R.XY
            16'b1111_011?_????_????: begin kind = K_DRAV; cyc = 6'd4; end
            16'b1111_100?_????_????: begin kind = K_PIXT; pixt_m = 3'd4; cyc = 6'd2; end // R,*R
            16'b1111_101?_????_????: begin kind = K_PIXT; pixt_m = 3'd5; cyc = 6'd4; end // *R,R
            16'b1111_110?_????_????: begin kind = K_PIXT; pixt_m = 3'd6; cyc = 6'd4; end // *R,*R
            16'b1111_111?_????_????: begin kind = K_ILLOP; cyc = 6'd16; end
            default: ;
        endcase
    end

    // ------------------------------------------------------ the field engine
    // (bit address, size, read or write) -> MAME's sequence of word
    // transactions.  `fe_words` is how many words the field is laid over.
    logic [31:0] fe_addr, fe_wdata, fe_rdata;
    logic  [5:0] fe_size;
    logic        fe_wr;
    logic [15:0] fe_w [4];              // the words read
    logic  [3:0] fe_step;

    wire   [3:0] fe_sh    = fe_addr[3:0];
    wire   [6:0] fe_end   = {3'd0, fe_sh} + {1'b0, fe_size};     // bits past the base
    wire         fe_big   = (fe_size >= 6'd18) && (fe_size <= 6'd31);
    // words MAME reads for this field
    wire   [2:0] fe_nrd   = (fe_size == 6'd32) ? ((fe_sh != 4'd0) ? 3'd4 : 3'd2)
                          : (fe_size >= 6'd17) ? ((fe_end > 7'd32) ? 3'd3 : 3'd2)
                          :                      ((fe_end > 7'd16) ? 3'd2 : 3'd1);
    // an aligned 16- or 32-bit write is a plain write, no read first
    wire         fe_plain = fe_wr && (fe_sh == 4'd0)
                                  && ((fe_size == 6'd16) || (fe_size == 6'd32));

    // The script: what transaction is step `s`?  {valid, write, word index}
    function automatic logic [3:0] fe_script(input logic [3:0] s);
        logic [2:0] n;
        n = fe_nrd;
        if (!fe_wr) begin
            return (s < {1'b0, n}) ? {1'b1, 1'b0, s[1:0]} : 4'b0000;
        end else if (fe_plain) begin
            return (s < {1'b0, n}) ? {1'b1, 1'b1, s[1:0]} : 4'b0000;
        end else if (fe_big && (n == 3'd3)) begin
            // MAME's order for a field over three words: R0 R1 W0 W1 R2 W2
            case (s)
                4'd0: return 4'b1_0_00;
                4'd1: return 4'b1_0_01;
                4'd2: return 4'b1_1_00;
                4'd3: return 4'b1_1_01;
                4'd4: return 4'b1_0_10;
                4'd5: return 4'b1_1_10;
                default: return 4'b0000;
            endcase
        end else begin
            // every word read, then every word written
            if (s < {1'b0, n})            return {1'b1, 1'b0, s[1:0]};
            if (s < {n, 1'b0})            return {1'b1, 1'b1, 2'(s - {1'b0, n})};
            return 4'b0000;
        end
    endfunction

    wire  [3:0] fe_now   = fe_script(fe_step);
    wire [63:0] fe_old   = {fe_w[3], fe_w[2], fe_w[1], fe_w[0]};
    wire [63:0] fe_m64   = {32'd0, fmask(fe_size)} << fe_sh;
    wire [63:0] fe_new   = (fe_old & ~fe_m64)
                         | (({32'd0, fe_wdata & fmask(fe_size)} << fe_sh) & fe_m64);
    wire [63:0] fe_shd   = fe_old >> fe_sh;
    assign fe_rdata      = fe_shd[31:0] & fmask(fe_size);
    wire [27:0] fe_base  = fe_addr[31:4];

    // ---------------------------------------------------------- the machine
    typedef enum logic [5:0] {
        S_RESET, S_RESET2,
        S_IRQ, S_FETCH, S_DECODE, S_EXT, S_EXEC,
        S_FE, S_FE_BUS,
        S_MV_SRCPRE, S_MV_READ, S_MV_SRCPOST, S_MV_DSTPRE, S_MV_WRITE, S_MV_DSTPOST,
        S_PUSH2, S_VEC, S_VEC2,
        S_POP2, S_RET2,
        S_MM_NEXT, S_MM_DONE,
        S_JREAD, S_JREAD2, S_CALL2,
        S_MUL, S_MUL2, S_DIV, S_DIV2,
        S_PIX_RD, S_PIX_SRT, S_PIX_SRTW, S_PIX_WR, S_PIX_END,
        G_INIT, G_ROW, G_ROWSRC, G_SEG, G_RDDST, G_PIX, G_SRCRD, G_WRDST, G_ROWEND, G_FIN,
        S_DONE
    } st_t;
    // S_FETCH is 3, and sim/tb_cpu.cpp's warm start relies on it.  (What the
    // benches may read and poke in here is listed in sim/tb_public.vlt, not
    // marked in this file: Verilator 5.020, which is what CI lints with, takes
    // a public_flat_rw pragma for a second, blocking writer and refuses it.)
    st_t   state;
    st_t   fe_ret;

    logic [15:0] ext [4];
    logic  [2:0] ext_i;
    logic        ext_seen;              // this instruction's cycles are charged
    logic [31:0] t_a, t_data;           // scratch between states
    logic  [4:0] mm_i;                  // MMTM/MMFM register counter
    logic [15:0] mm_list;
    // Pacing.  Every instruction owes MAME's cycle count; every `cen` pays one
    // cycle off; the next instruction starts when nothing is owed.  The
    // balance may run CREDIT cycles into credit, so an instruction that took
    // longer than its count -- MAME charges MOVE Rs,*Rd+ one cycle, 19 clocks,
    // and two word writes through a real bus take longer than that -- is
    // repaid by the register-only instructions around it, which finish in
    // half theirs.  Without the credit the power-up tests ran 6% behind
    // MAME: the machine's frame 640 was MAME's frame 600.
    //
    // The balance is wide because FILL and PIXBLT owe a great deal at once: a
    // full-screen FILL is 262,000 cycles, and the writes themselves take a
    // fraction of that.  It was 11 bits, which wrapped after about three rows
    // of a large FILL and forgot the debt - the machine ran AHEAD of MAME
    // wherever the program clears a screen (12 ms by the end of the power-up
    // tests, measured from the core's own sound-command log).
    localparam logic signed [27:0] CREDIT = -28'sd64;
    logic signed [27:0] bal;
    logic        [15:0] cyc_add;        // cycles this clock adds to the debt
    logic               cyc_stb;
    // every cycle ever charged, for the bench to hold against MAME's count
    // (sim/tb_cpu.cpp); nothing reads it, so synthesis removes it
    logic        [31:0] cyc_total;
    logic [31:0] vec_addr;
    logic        push_st_too;           // a trap or interrupt: push ST after PC
    logic [31:0] ret_pc;

    wire [31:0] imm_w = {{16{ext[0][15]}}, ext[0]};
    wire [31:0] imm_l = {ext[1], ext[0]};
    wire [31:0] imm   = lng ? imm_l : imm_w;

    // field parameters for the current MOVE
    wire  [4:0] mv_fs   = (m_fld == 2'd1) ? st[10:6] : st[4:0];
    wire        mv_fe   = (m_fld == 2'd1) ? st[11]   : st[5];
    wire  [5:0] mv_size = (m_fld == 2'd2) ? 6'd8 : fsize(mv_fs);
    wire [31:0] mv_inc  = {26'd0, mv_size};

    // where the MOVE's extension words are: the source's first
    wire  [2:0] src_ext = (m_src == AM_ABS) ? 3'd2 : (m_src == AM_OFF) ? 3'd1 : 3'd0;
    wire [31:0] src_off = {{16{ext[0][15]}}, ext[0]};
    wire [31:0] src_abs = {ext[1], ext[0]};
    wire [31:0] dst_off = {{16{ext[src_ext[1:0]][15]}}, ext[src_ext[1:0]]};
    wire [31:0] dst_abs = {ext[2'(src_ext + 3'd1)], ext[src_ext[1:0]]};

    // ------------------------------------------------------------ the ALU
    logic [31:0] a_src, a_dst, a_res;
    logic        f_n, f_c, f_z, f_v;    // flags this instruction produces
    logic  [3:0] f_we;                  // which of N C Z V it writes
    logic        a_wr;                  // write a_res to Rd
    logic  [4:0] sh_k;
    logic [32:0] add33;
    logic [31:0] sla_mask, sla_r2;

    wire [31:0] r_s = rget(fR, rs);
    wire [31:0] r_d = rget(fR, rd);
    wire        cin = st[ST_C];

    function automatic logic [31:0] k32(input logic [4:0] k);
        return (k == 5'd0) ? 32'd32 : {27'd0, k};
    endfunction

    function automatic logic v_add(input logic [31:0] a, b, r);
        return (~(a[31] ^ b[31])) & (a[31] ^ r[31]);
    endfunction
    function automatic logic v_sub(input logic [31:0] a, b, r);   // r = a - b
        return (a[31] ^ b[31]) & (a[31] ^ r[31]);
    endfunction

    always_comb begin
        a_src = r_s; a_dst = r_d; a_res = r_d;
        f_n = 1'b0; f_c = 1'b0; f_z = 1'b0; f_v = 1'b0; f_we = 4'b0000; a_wr = 1'b0;
        sh_k = 5'd0; add33 = '0; sla_mask = '0; sla_r2 = '0;

        // operand selection
        case (kind)
            K_ADDI, K_MOVI:  a_src = imm;
            K_CMPI, K_SUBI:  a_src = ~imm;
            K_ANDI:          a_src = ~imm_l;
            K_ORI, K_XORI:   a_src = imm_l;
            K_ADDK, K_SUBK:  a_src = k32(kf);
            K_ANDN:          a_src = ~r_s;
            default: ;
        endcase

        case (kind)
            K_ADD, K_ADDI, K_ADDK, K_ADDC: begin
                a_res = a_src + a_dst + ((kind == K_ADDC && cin) ? 32'd1 : 32'd0);
                add33 = {1'b0, a_src} + {1'b0, a_dst};        // MAME: carry-in ignored
                f_c = add33[32]; f_v = v_add(a_src, a_dst, a_res);
                f_n = a_res[31]; f_z = (a_res == 32'd0); f_we = 4'b1111; a_wr = 1'b1;
            end
            K_SUB, K_SUBI, K_SUBK, K_SUBB, K_CMP, K_CMPI: begin
                a_res = a_dst - a_src - ((kind == K_SUBB && cin) ? 32'd1 : 32'd0);
                f_c = (a_src > a_dst);                         // MAME: borrow-in ignored
                f_v = v_sub(a_dst, a_src, a_res);
                f_n = a_res[31]; f_z = (a_res == 32'd0); f_we = 4'b1111;
                a_wr = !(kind == K_CMP || kind == K_CMPI);
            end
            K_NEG, K_NEGB: begin
                a_src = r_d + ((kind == K_NEGB && cin) ? 32'd1 : 32'd0);
                a_res = 32'd0 - a_src;
                f_c = (a_src != 32'd0); f_v = v_sub(32'd0, a_src, a_res);
                f_n = a_res[31]; f_z = (a_res == 32'd0); f_we = 4'b1111; a_wr = 1'b1;
            end
            K_ABS: begin
                a_res = 32'd0 - r_d;
                f_n = a_res[31]; f_z = (a_res == 32'd0); f_v = (a_res == 32'h8000_0000);
                f_we = 4'b1011;
                a_wr = !a_res[31] && (a_res != 32'd0);         // only if the negation is > 0
            end
            K_AND, K_ANDI, K_ANDN: begin
                a_res = a_dst & a_src; f_z = (a_res == 32'd0); f_we = 4'b0010; a_wr = 1'b1;
            end
            K_OR, K_ORI: begin
                a_res = a_dst | a_src; f_z = (a_res == 32'd0); f_we = 4'b0010; a_wr = 1'b1;
            end
            K_XOR, K_XORI: begin
                a_res = a_dst ^ a_src; f_z = (a_res == 32'd0); f_we = 4'b0010; a_wr = 1'b1;
            end
            K_NOT: begin
                a_res = ~r_d; f_z = (a_res == 32'd0); f_we = 4'b0010; a_wr = 1'b1;
            end
            K_MOVI: begin
                a_res = a_src; f_n = a_res[31]; f_z = (a_res == 32'd0);
                f_we = 4'b1011; a_wr = 1'b1;
            end
            K_MOVK: begin a_res = k32(kf); a_wr = 1'b1; end
            K_BTSTK: begin f_z = ~r_d[~kf]; f_we = 4'b0010; end
            K_BTSTR: begin f_z = ~r_d[r_s[4:0]]; f_we = 4'b0010; end
            K_SEXT: begin
                a_res = sext_n(r_d, fsize(fsel[0] ? st[10:6] : st[4:0]));
                f_n = a_res[31]; f_z = (a_res == 32'd0); f_we = 4'b1010; a_wr = 1'b1;
            end
            K_ZEXT: begin
                a_res = r_d & fmask(fsize(fsel[0] ? st[10:6] : st[4:0]));
                f_z = (a_res == 32'd0); f_we = 4'b0010; a_wr = 1'b1;
            end
            K_SLA, K_SLL, K_RL: begin
                sh_k = shr ? r_s[4:0] : kf;
                if (kind == K_RL) a_res = (r_d << sh_k) | (r_d >> (5'd0 - sh_k));
                else              a_res = r_d << sh_k;
                if (sh_k == 5'd0) a_res = r_d;
                // the last bit out is bit (32 - k) of the original
                f_c = (sh_k != 5'd0) && r_d[5'd0 - sh_k];
                f_z = (a_res == 32'd0); f_n = a_res[31];
                sla_mask = (32'hffff_ffff << (5'd31 - sh_k)) & 32'h7fff_ffff;
                sla_r2   = r_d[31] ? (r_d ^ sla_mask) : r_d;
                f_v = (sh_k != 5'd0) && ((sla_r2 & sla_mask) != 32'd0);
                f_we = (kind == K_SLA) ? 4'b1111 : 4'b0110;
                a_wr = (sh_k != 5'd0);
            end
            K_SRA, K_SRL: begin
                sh_k = 5'd0 - (shr ? r_s[4:0] : kf);
                if (kind == K_SRA) a_res = 32'($signed(r_d) >>> sh_k);
                else               a_res = r_d >> sh_k;
                f_c = (sh_k != 5'd0) && r_d[sh_k - 5'd1];
                f_z = (a_res == 32'd0); f_n = a_res[31];
                f_we = (kind == K_SRA) ? 4'b1110 : 4'b0110;
                a_wr = (sh_k != 5'd0);
            end
            K_LMO: begin
                a_res = 32'd0;
                for (int i = 0; i < 32; i++)
                    if (r_s[i]) a_res = 32'(31 - i);
                f_z = (r_s == 32'd0); f_we = 4'b0010; a_wr = 1'b1;
            end
            K_ADDXY: begin
                a_res = {r_d[31:16] + r_s[31:16], r_d[15:0] + r_s[15:0]};
                f_n = (a_res[15:0] == 16'd0); f_c = a_res[31];
                f_z = (a_res[31:16] == 16'd0); f_v = a_res[15];
                f_we = 4'b1111; a_wr = 1'b1;
            end
            K_SUBXY: begin
                a_res = {r_d[31:16] - r_s[31:16], r_d[15:0] - r_s[15:0]};
                f_n = (r_s[15:0] == r_d[15:0]);
                f_c = ($signed(r_s[31:16]) > $signed(r_d[31:16]));
                f_z = (r_s[31:16] == r_d[31:16]);
                f_v = ($signed(r_s[15:0]) > $signed(r_d[15:0]));
                f_we = 4'b1111; a_wr = 1'b1;
            end
            K_CMPXY: begin
                a_res = {r_d[31:16] - r_s[31:16], r_d[15:0] - r_s[15:0]};
                f_n = (a_res[15:0] == 16'd0); f_v = a_res[15];
                f_z = (a_res[31:16] == 16'd0); f_c = a_res[31];
                f_we = 4'b1111;
            end
            K_MOVX: begin a_res = {r_d[31:16], r_s[15:0]}; a_wr = 1'b1; end
            K_MOVY: begin a_res = {r_s[31:16], r_d[15:0]}; a_wr = 1'b1; end
            default: ;
        endcase
    end

    // condition codes, in the order the opcode's bits 11-8 number them
    logic take;
    wire  N = st[ST_N], C = st[ST_C], Z = st[ST_Z], V = st[ST_V];
    always_comb begin
        case (ir[11:8])
            4'h0: take = 1'b1;
            4'h1: take = !N && !Z;                  // P
            4'h2: take = C || Z;                    // LS
            4'h3: take = !C && !Z;                  // HI
            4'h4: take = (N != V);                  // LT
            4'h5: take = (N == V);                  // GE
            4'h6: take = (N != V) || Z;             // LE
            4'h7: take = (N == V) && !Z;            // GT
            4'h8: take = C;
            4'h9: take = !C;
            4'ha: take = Z;
            4'hb: take = !Z;
            4'hc: take = V;
            4'hd: take = !V;
            4'he: take = N;
            default: take = !N;
        endcase
    end

    // XY to linear, destination pitch: y * 2^n + (x << log2(psize)) + OFFSET
    function automatic logic [31:0] xytol(input logic [31:0] xy, input logic [15:0] conv);
        logic [31:0] y, x;
        logic  [2:0] ps;
        y = {{16{xy[31]}}, xy[31:16]} << (~conv[4:0]);
        ps = io_psize[4] ? 3'd4 : io_psize[3] ? 3'd3 : io_psize[2] ? 3'd2
           : io_psize[1] ? 3'd1 : 3'd0;
        x = {{16{xy[15]}}, xy[15:0]} << ps;
        return y + x + rb[4];
    endfunction
    wire [5:0]  psize6   = (io_psize[5:0] == 6'd0) ? 6'd1 : io_psize[5:0];
    wire [31:0] pix_amsk = ~{26'd0, psize6 - 6'd1};     // align to a pixel

    // CPW: which sides of the window (B5 start, B6 end) the point is outside
    wire [31:0] cpw_res = {23'd0,
                           ($signed(r_s[31:16])  > $signed(rb[6][31:16])),
                           ($signed(rb[5][31:16]) > $signed(r_s[31:16])),
                           ($signed(r_s[15:0])   > $signed(rb[6][15:0])),
                           ($signed(rb[5][15:0])  > $signed(r_s[15:0])), 5'd0};

    // MPYS takes its multiplier through field 1's size, sign-extended;
    // MPYU the same, zero-extended
    wire [31:0] mpy_sx = sext_n(r_s, fsize(st[10:6]));
    wire [31:0] mpy_zx = r_s & fmask(fsize(st[10:6]));

    // the divider's operands, as magnitudes
    wire        div_sgn  = (kind == K_DIVS) || (kind == K_MODS);
    wire        div_w    = ((kind == K_DIVS) || (kind == K_DIVU)) && !rd[0];
    wire [63:0] div_n0   = div_w   ? {r_d, rget(fR, rd | 4'd1)}
                         : div_sgn ? {{32{r_d[31]}}, r_d} : {32'd0, r_d};
    wire [64:0] div_rsh  = {div_r[63:0], div_n[63]};
    wire [63:0] div_qs   = div_neg_q ? (64'd0 - div_q) : div_q;
    wire [31:0] div_rem  = div_neg_r ? (32'd0 - div_r[31:0]) : div_r[31:0];
    wire        div_ovf  = (kind == K_DIVS) ? (div_qs[63:31] != {33{div_qs[31]}})
                                            : (div_q[63:32] != 32'd0);

    // the pixel a PIXT or DRAV is about to write
    wire        pix_from_reg = (kind == K_DRAV) || (pixt_m == 3'd0) || (pixt_m == 3'd4);
    logic [15:0] srt_val;
    wire [31:0] pix_val  = pix_from_reg ? (t_data & fmask(psize6))
                         : io_srt       ? {16'd0, srt_val} : fe_rdata;

    // ---- PIXBLT B and FILL (MAME's pixblt_b and fill in 34010gfx.hxx)
    // A row is a left partial word, some full words and a right partial word
    // of the destination; PIXBLT B also walks a 1-bit-per-pixel source,
    // fetching its next word the moment the current one runs out -- before
    // the destination word is written back, which is the order the bus trace
    // has them in.
    wire         g_fill = ir[6];
    wire         g_xy   = ir[5];
    wire   [2:0] g_l2   = io_psize[4] ? 3'd4 : io_psize[3] ? 3'd3 : io_psize[2] ? 3'd2
                        : io_psize[1] ? 3'd1 : 3'd0;           // log2(bits per pixel)
    wire   [4:0] g_bpp  = 5'd1 << g_l2;
    wire   [4:0] g_ppw  = 5'd16 >> g_l2;                       // pixels per word
    wire  [31:0] g_d0   = (g_xy ? xytol(rb[2], io_convdp) : rb[2]) & ~{27'd0, g_bpp - 5'd1};
    wire signed [16:0] g_dx = {rb[7][15], rb[7][15:0]};
    wire signed [16:0] g_dy = {rb[7][31], rb[7][31:16]};
    wire   [4:0] g_lp0  = (g_ppw - {1'b0, (g_d0[3:0] >> g_l2)}) & (g_ppw - 5'd1);
    wire  [31:0] g_end  = g_d0 + ({15'd0, g_dx} << g_l2);
    wire   [4:0] g_rp0  = {1'b0, g_end[3:0] >> g_l2};
    wire signed [17:0] g_fw0 = {g_dx[16], g_dx} - {13'd0, g_lp0} - {13'd0, g_rp0};

    logic [31:0] g_saddr, g_daddr, g_dacc;
    logic [27:0] g_sword, g_dword;
    logic [15:0] g_srcw, g_dstw, g_y, g_fw, g_fwc;
    // what MAME charges for one row: `op timing` (2, or 4 with transparency)
    // per destination word, a partial word counting as a word, and for a
    // PIXBLT B two more per source word, of which it reckons there are
    // dstwords * psize / 16
    wire  [15:0] g_dw     = g_fw + {15'd0, g_lp != 5'd0} + {15'd0, g_rp != 5'd0};
    wire  [15:0] g_rowcyc = (io_control[5] ? (g_dw << 2) : (g_dw << 1))
                          + (g_fill ? 16'd0 : ((g_dw >> (3'd4 - g_l2)) << 1));
    logic  [4:0] g_lp, g_rp, g_cnt;
    logic  [3:0] g_sbit, g_dpos;
    logic  [1:0] g_seg;
    // this pixel: the colour's bits at this position in the word
    wire  [15:0] g_pmask = (16'hffff >> (5'd16 - g_bpp)) << g_dpos;
    wire  [15:0] g_col   = (g_fill || g_srcw[g_sbit]) ? rb[9][15:0] : rb[8][15:0];
    wire  [15:0] g_pixel = g_col & g_pmask;
    wire         g_keep  = io_control[5] && (g_pixel == 16'd0);  // transparent

    // pending, enabled interrupts, in priority order
    wire [15:0] irq_act = io_intpend & io_intenb;
    wire        irq_any = st[ST_IE] && (irq_act != 16'd0);
    wire [31:0] irq_vec = irq_act[9]  ? 32'hffff_fec0      // host
                        : irq_act[10] ? 32'hffff_fea0      // display
                        : irq_act[11] ? 32'hffff_fe80      // window violation
                        : irq_act[1]  ? 32'hffff_ffc0      // external 1
                        :               32'hffff_ffa0;     // external 2

    // the multiplier and the divider
    logic signed [32:0] mul_a, mul_b;
    logic signed [65:0] mul_p;
    logic        [63:0] div_n, div_q;
    logic        [64:0] div_r;
    logic        [31:0] div_d;
    logic         [6:0] div_i;
    logic               div_neg_q, div_neg_r, div_wide;

    // A macro, not a task: a task that writes module state is something a
    // synthesiser has to interpret (METHODOLOGY 5.13 lost results that way),
    // and a macro is just the text.
// Writes to the register file go through ONE port (and a second, for the three
// instructions that write a pair: MMFM, the 64-bit multiplies and divides).
// Each site used to assign ra[i]/rb[i] itself, which makes every one of the 31
// registers' inputs a multiplexer over all thirty sites - about a quarter of
// this CPU's logic when it was measured.  Now the sites set these, the last
// one to run in a clock wins as before, and the file is written once, at the
// foot of the block.  They are blocking temporaries, not state.
`define SET_REG(f, i, v)  begin w_en  = 1'b1; w_f  = (f); w_i  = (i); w_v  = (v); end
`define SET_REG2(f, i, v) begin w2_en = 1'b1; w2_f = (f); w2_i = (i); w2_v = (v); end
    /* verilator lint_off BLKSEQ */
    logic        w_en, w_f, w2_en, w2_f;
    logic  [3:0] w_i, w2_i;
    logic [31:0] w_v, w2_v;

    // a bus write the CPU makes to one of its own I/O registers
    wire io_hit = (bus_addr[31:9] == 23'h600000);          // 0xC0000000..0xC00001FF
    wire [4:0] io_reg = bus_addr[8:4];

    always_ff @(posedge clk) if (step || rst_q) begin
        w_en = 1'b0; w_f = 1'b0; w_i = 4'd0; w_v = 32'd0;
        w2_en = 1'b0; w2_f = 1'b0; w2_i = 4'd0; w2_v = 32'd0;
        insn_start_q <= 1'b0;
        irq_taken_q  <= 1'b0;

        // interrupt pending bits: the pins are levels, the display is a pulse
        io_intpend[1] <= int1;
        io_intpend[2] <= int2;
        if (dpy_l) io_intpend[10] <= 1'b1;

        cyc_stb <= 1'b0;

        if (rst_q) begin
            state <= S_RESET; st <= 32'h0000_0010; pc <= '0; sp <= '0;
            for (int i = 0; i < 15; i++) begin ra[i] <= '0; rb[i] <= '0; end
            io_control <= '0; io_convsp <= '0; io_convdp <= '0; io_psize <= '0;
            io_pmask <= '0; io_intenb <= '0; io_intpend <= '0; io_srt <= 1'b0; bus_srt <= 1'b0;
            q_req <= 1'b0; bus_we <= 1'b0; unimpl <= 1'b0; cyc_stb <= 1'b0; ext_seen <= 1'b0;
            push_st_too <= 1'b0;
        end else case (state)
            // ------------------------------------------------ reset
            S_RESET: begin
                fe_addr <= 32'hffff_ffe0; fe_size <= 6'd32; fe_wr <= 1'b0;
                fe_ret <= S_RESET2; state <= S_FE;
            end
            S_RESET2: begin
                pc <= {fe_rdata[31:4], 4'd0}; st <= 32'h0000_0010; state <= S_FETCH;
            end

            // ------------------------------------------------ fetch
            S_FETCH: begin
                if (irq_any) begin
                    state <= S_IRQ;
                end else begin
                    insn_start_q <= 1'b1;
                    q_req <= 1'b1; bus_we <= 1'b0; bus_addr <= pc[31:4];
                    state <= S_DECODE;
                end
            end
            S_DECODE: if (q_ack) begin
                q_req <= 1'b0;
                ir      <= q_rdata;
                pc      <= pc + 32'd16;
                ext_i   <= 3'd0;
                state   <= S_EXT;
            end
            // extension words, then execute.  `next` is combinational on ir.
            S_EXT: begin
                if (ext_i == 3'd0 && !ext_seen) begin cyc_add <= {10'd0, cyc}; cyc_stb <= 1'b1; ext_seen <= 1'b1; end
                if (ext_i == next) begin
                    state <= S_EXEC;
                end else if (!q_req) begin
                    q_req <= 1'b1; bus_we <= 1'b0; bus_addr <= pc[31:4];
                end else if (q_ack) begin
                    q_req <= 1'b0;
                    ext[ext_i[1:0]] <= q_rdata;
                    pc    <= pc + 32'd16;
                    ext_i <= ext_i + 3'd1;
                end
            end

            // ------------------------------------------------ interrupt entry
            S_IRQ: begin
                irq_taken_q   <= 1'b1;
                vec_addr    <= irq_vec;
                push_st_too <= 1'b1;
                ret_pc      <= pc;
                cyc_add <= 16'd16; cyc_stb <= 1'b1;
                // push PC
                sp <= sp - 32'd32;
                fe_addr <= sp - 32'd32; fe_size <= 6'd32; fe_wr <= 1'b1; fe_wdata <= pc;
                fe_ret <= S_PUSH2; state <= S_FE;
            end
            S_PUSH2: begin
                if (push_st_too) begin
                    sp <= sp - 32'd32;
                    fe_addr <= sp - 32'd32; fe_size <= 6'd32; fe_wr <= 1'b1; fe_wdata <= st;
                    fe_ret <= S_VEC; state <= S_FE;
                end else state <= S_VEC;
            end
            S_VEC: begin
                st <= 32'h0000_0010;
                fe_addr <= vec_addr; fe_size <= 6'd32; fe_wr <= 1'b0;
                fe_ret <= S_VEC2; state <= S_FE;
            end
            S_VEC2: begin
                pc <= {fe_rdata[31:4], 4'd0}; state <= S_DONE;
            end

            // ------------------------------------------------ execute
            S_EXEC: begin
                state <= S_DONE;
                // the common case: a result and some flags
                if (a_wr) `SET_REG(fR, rd, a_res)
                if (f_we[3]) st[ST_N] <= f_n;
                if (f_we[2]) st[ST_C] <= f_c;
                if (f_we[1]) st[ST_Z] <= f_z;
                if (f_we[0]) st[ST_V] <= f_v;

                case (kind)
                    K_UNIMPL: begin unimpl <= 1'b1; end
                    K_ILLOP: begin
                        vec_addr <= 32'hffff_fc20; push_st_too <= 1'b1;
                        sp <= sp - 32'd32;
                        fe_addr <= sp - 32'd32; fe_size <= 6'd32; fe_wr <= 1'b1; fe_wdata <= pc;
                        fe_ret <= S_PUSH2; state <= S_FE;
                    end
                    K_REV:   `SET_REG(fR, rd, 32'h0000_0008)
                    K_EXGPC: begin `SET_REG(fR, rd, pc) pc <= {r_d[31:4], 4'd0}; end
                    K_GETPC: `SET_REG(fR, rd, pc)
                    K_JUMP:  pc <= {r_d[31:4], 4'd0};
                    K_GETST: `SET_REG(fR, rd, st)
                    K_PUTST: st <= r_d;
                    K_CLRC:  st[ST_C] <= 1'b0;
                    K_SETC:  st[ST_C] <= 1'b1;
                    K_DINT:  st[ST_IE] <= 1'b0;
                    K_EINT:  st[ST_IE] <= 1'b1;
                    K_SETF: begin
                        if (fsel[0]) st[11:6] <= ir[5:0];
                        else         st[5:0]  <= ir[5:0];
                    end
                    K_EXGF: begin
                        if (fsel[0]) begin st[11:6] <= r_d[5:0]; `SET_REG(fR, rd, {26'd0, st[11:6]}) end
                        else         begin st[5:0]  <= r_d[5:0]; `SET_REG(fR, rd, {26'd0, st[5:0]})  end
                    end
                    K_MOVERR: begin
                        // 4C/4D stay in one file; 4E/4F cross to the other
                        `SET_REG(ir[9] ? ~fR : fR, rd, r_s)
                        st[ST_N] <= r_s[31]; st[ST_Z] <= (r_s == 32'd0); st[ST_V] <= 1'b0;
                    end
                    K_CPW: begin
                        `SET_REG(fR, rd, cpw_res)
                        st[ST_V] <= (cpw_res != 32'd0);
                    end
                    K_CVXYL: `SET_REG(fR, rd, xytol(r_s, io_convdp))

                    // ---- stack and flow
                    K_PUSHST: begin
                        sp <= sp - 32'd32;
                        fe_addr <= sp - 32'd32; fe_size <= 6'd32; fe_wr <= 1'b1; fe_wdata <= st;
                        fe_ret <= S_DONE; state <= S_FE;
                    end
                    K_POPST: begin
                        fe_addr <= sp; fe_size <= 6'd32; fe_wr <= 1'b0;
                        sp <= sp + 32'd32;
                        fe_ret <= S_POP2; state <= S_FE;
                    end
                    K_CALL: begin
                        sp <= sp - 32'd32;
                        fe_addr <= sp - 32'd32; fe_size <= 6'd32; fe_wr <= 1'b1; fe_wdata <= pc;
                        pc <= {r_d[31:4], 4'd0};
                        fe_ret <= S_DONE; state <= S_FE;
                    end
                    K_CALLR, K_CALLA: begin
                        // MAME pushes first and fetches the operand after
                        sp <= sp - 32'd32;
                        fe_addr <= sp - 32'd32; fe_size <= 6'd32; fe_wr <= 1'b1;
                        fe_wdata <= pc + ((kind == K_CALLA) ? 32'd32 : 32'd16);
                        fe_ret <= S_JREAD; state <= S_FE;
                    end
                    K_TRAP: begin
                        vec_addr <= 32'hffff_ffe0 - {22'd0, ir[4:0], 5'd0};
                        if (ir[4:0] != 5'd0) begin
                            push_st_too <= 1'b1;
                            sp <= sp - 32'd32;
                            fe_addr <= sp - 32'd32; fe_size <= 6'd32; fe_wr <= 1'b1;
                            fe_wdata <= pc;
                            fe_ret <= S_PUSH2; state <= S_FE;
                        end else state <= S_VEC;
                    end
                    K_RETI: begin
                        fe_addr <= sp; fe_size <= 6'd32; fe_wr <= 1'b0; sp <= sp + 32'd32;
                        fe_ret <= S_POP2; state <= S_FE;
                    end
                    K_RETS: begin
                        fe_addr <= sp; fe_size <= 6'd32; fe_wr <= 1'b0; sp <= sp + 32'd32;
                        fe_ret <= S_RET2; state <= S_FE;
                    end

                    // ---- decrement and jump
                    K_DSJS: begin
                        `SET_REG(fR, rd, r_d - 32'd1)
                        if (r_d != 32'd1)
                            pc <= ir[10] ? (pc - {23'd0, kf, 4'd0}) : (pc + {23'd0, kf, 4'd0});
                        else begin cyc_add <= 16'd1; cyc_stb <= 1'b1; end   // 3, not 2
                    end
                    K_DSJ, K_DSJEQ, K_DSJNE: begin
                        if ((kind == K_DSJ) || (kind == K_DSJEQ && Z) || (kind == K_DSJNE && !Z)) begin
                            `SET_REG(fR, rd, r_d - 32'd1)
                            if (r_d != 32'd1) begin
                                state <= S_JREAD; cyc_add <= 16'd1; cyc_stb <= 1'b1;
                            end else pc <= pc + 32'd16;
                        end else pc <= pc + 32'd16;
                    end
                    K_JCC: begin
                        // MAME's counts: 8-bit 2 taken, 1 not; 16-bit 3 and 2;
                        // absolute 3 and 4.  Decode charged 1 already.
                        cyc_stb <= 1'b1;
                        if (ir[7:0] == 8'h00) begin           // 16-bit relative
                            if (take) begin state <= S_JREAD; cyc_add <= 16'd2; end
                            else      begin pc <= pc + 32'd16; cyc_add <= 16'd1; end
                        end else if (ir[7:0] == 8'h80) begin  // absolute
                            if (take) begin state <= S_JREAD; cyc_add <= 16'd2; end
                            else      begin pc <= pc + 32'd32; cyc_add <= 16'd3; end
                        end else begin                         // 8-bit relative
                            if (take) begin
                                pc <= pc + {{20{ir[7]}}, ir[7:0], 4'd0}; cyc_add <= 16'd1;
                            end else cyc_add <= 16'd0;
                        end
                    end

                    // ---- register lists
                    K_MMTM, K_MMFM: begin
                        mm_list <= ext[0]; mm_i <= 5'd0; state <= S_MM_NEXT;
                    end

                    // ---- multiply and divide
                    K_MPYS: begin
                        mul_a <= $signed({mpy_sx[31], mpy_sx});
                        mul_b <= $signed({r_d[31], r_d});
                        state <= S_MUL;
                    end
                    K_MPYU: begin
                        mul_a <= $signed({1'b0, mpy_zx});
                        mul_b <= $signed({1'b0, r_d});
                        state <= S_MUL;
                    end
                    K_DIVS, K_DIVU, K_MODS, K_MODU: begin
                        if (r_s == 32'd0) begin
                            // divide by zero: V, and nothing else changes
                            st[ST_V] <= 1'b1;
                            if (kind == K_DIVS || kind == K_MODS) begin st[ST_N] <= 1'b0; end
                            st[ST_Z] <= 1'b0;
                        end else begin
                            div_wide <= div_w;
                            state    <= S_DIV;
                        end
                    end

                    // ---- memory moves
                    K_MOVE: state <= S_MV_SRCPRE;

                    // ---- pixels
                    K_GFX: begin
                        if (io_control[14:10] != 5'd0 || io_control[7:6] != 2'd0
                            || io_pmask != 16'd0 || io_psize[5]) unimpl <= 1'b1;
                        state <= G_INIT;
                    end
                    K_PIXT, K_DRAV: begin
                        if (io_control[14:10] != 5'd0 || io_control[7:6] != 2'd0
                            || io_pmask != 16'd0) unimpl <= 1'b1;
                        state <= S_PIX_RD;
                    end
                    default: ;
                endcase
            end

            // ------------------------------------------------ MOVE, step by step
            // In MAME's order, re-reading the register file at each step, so
            // that MOVE *A1+,A1 and its relatives come out the way they do there.
            S_MV_SRCPRE: begin
                if (m_src == AM_PD) `SET_REG(fR, rs, r_s - mv_inc)
                state <= (m_src == AM_REG) ? S_MV_DSTPRE : S_MV_READ;
                if (m_src == AM_REG) t_data <= rget(fR, m_dreg);
            end
            S_MV_READ: begin
                fe_addr <= (m_src == AM_ABS) ? src_abs
                         : (m_src == AM_OFF) ? (r_s + src_off) : r_s;
                fe_size <= mv_size; fe_wr <= 1'b0;
                fe_ret <= S_MV_SRCPOST; state <= S_FE;
            end
            S_MV_SRCPOST: begin
                // MOVB to a register always sign-extends; MOVE follows FE
                t_data <= (m_fld == 2'd2) ? sext_n(fe_rdata, 6'd8)
                        : mv_fe          ? sext_n(fe_rdata, mv_size) : fe_rdata;
                if (m_src == AM_PI) `SET_REG(fR, rs, r_s + mv_inc)
                state <= S_MV_DSTPRE;
            end
            S_MV_DSTPRE: begin
                if (m_dst == AM_PD) `SET_REG(fR, rd, r_d - mv_inc)
                state <= S_MV_WRITE;
            end
            S_MV_WRITE: begin
                if (m_dst == AM_REG) begin
                    `SET_REG(fR, rd, t_data)
                    st[ST_N] <= t_data[31]; st[ST_Z] <= (t_data == 32'd0); st[ST_V] <= 1'b0;
                    state <= S_DONE;
                end else begin
                    fe_addr <= (m_dst == AM_ABS) ? dst_abs
                             : (m_dst == AM_OFF) ? (r_d + dst_off) : r_d;
                    fe_size <= mv_size; fe_wr <= 1'b1; fe_wdata <= t_data;
                    fe_ret <= S_MV_DSTPOST; state <= S_FE;
                end
            end
            S_MV_DSTPOST: begin
                if (m_dst == AM_PI) `SET_REG(fR, rd, r_d + mv_inc)
                state <= S_DONE;
            end

            // ------------------------------------------------ returns
            S_POP2: begin
                if (kind == K_POPST) begin st <= fe_rdata; state <= S_DONE; end
                else begin                                   // RETI: ST, then PC
                    t_a <= fe_rdata;
                    fe_addr <= sp; fe_size <= 6'd32; fe_wr <= 1'b0; sp <= sp + 32'd32;
                    fe_ret <= S_RET2; state <= S_FE;
                end
            end
            S_RET2: begin
                pc <= {fe_rdata[31:4], 4'd0};
                if (kind == K_RETI) st <= t_a;
                else                sp <= sp + {23'd0, ir[4:0], 4'd0};
                state <= S_DONE;
            end

            // ------------------------------------------------ jump operands
            // Fetched only when the jump is taken, and without moving the PC:
            // MAME's PARAM_WORD_NO_INC and PARAM_LONG_NO_INC.
            S_JREAD: begin
                if (!q_req) begin
                    q_req <= 1'b1; bus_we <= 1'b0; bus_addr <= pc[31:4];
                end else if (q_ack) begin
                    q_req <= 1'b0;
                    ext[0]  <= q_rdata;
                    if ((kind == K_JCC && ir[7:0] == 8'h80) || kind == K_CALLA)
                        state <= S_JREAD2;
                    else begin
                        pc <= pc + {{12{q_rdata[15]}}, q_rdata, 4'd0} + 32'd16;
                        state <= S_DONE;
                    end
                end
            end
            S_JREAD2: begin
                if (!q_req) begin
                    q_req <= 1'b1; bus_we <= 1'b0; bus_addr <= pc[31:4] + 28'd1;
                end else if (q_ack) begin
                    q_req <= 1'b0;
                    pc      <= {q_rdata, ext[0][15:4], 4'd0};
                    state   <= S_DONE;
                end
            end

            // ------------------------------------------------ MMTM and MMFM
            // MMTM walks register 0 upwards, MMFM register 15 downwards, both
            // taking the list's top bit first.
            S_MM_NEXT: begin
                if (mm_i == 5'd16) state <= S_DONE;
                else begin
                    mm_list <= {mm_list[14:0], 1'b0};
                    mm_i    <= mm_i + 5'd1;
                    if (mm_list[15]) begin
                        cyc_add <= 16'd4; cyc_stb <= 1'b1;
                        if (kind == K_MMTM) begin
                            `SET_REG(fR, rd, r_d - 32'd32)
                            fe_addr <= r_d - 32'd32; fe_size <= 6'd32; fe_wr <= 1'b1;
                            // MAME decrements first, so a list that includes
                            // the pointer pushes the already-moved pointer
                            fe_wdata <= (mm_i[3:0] == rd) ? (r_d - 32'd32)
                                                          : rget(fR, mm_i[3:0]);
                            fe_ret <= S_MM_NEXT; state <= S_FE;
                        end else begin
                            fe_addr <= r_d; fe_size <= 6'd32; fe_wr <= 1'b0;
                            fe_ret <= S_MM_DONE; state <= S_FE;
                        end
                    end
                end
            end
            S_MM_DONE: begin
                // the register is loaded, and then the pointer moves on -- so
                // if they are the same register, the increment wins
                // (mm_i was already advanced)
                if (4'(5'd16 - mm_i) == rd) `SET_REG(fR, rd, fe_rdata + 32'd32)
                else begin
                    `SET_REG(fR, 4'(5'd16 - mm_i), fe_rdata)
                    `SET_REG2(fR, rd, r_d + 32'd32)
                end
                state <= S_MM_NEXT;
            end

            // ------------------------------------------------ multiply
            S_MUL:  begin mul_p <= mul_a * mul_b; state <= S_MUL2; end
            S_MUL2: begin
                st[ST_Z] <= (mul_p[63:0] == 64'd0);
                if (kind == K_MPYS) st[ST_N] <= mul_p[63];
                // an odd Rd has the low half land on top of the high half
                if (rd[0]) `SET_REG(fR, rd, mul_p[31:0])
                else begin
                    `SET_REG(fR, rd, mul_p[63:32])
                    `SET_REG2(fR, rd | 4'd1, mul_p[31:0])
                end
                state <= S_DONE;
            end

            // ------------------------------------------------ divide
            // A restoring divider over magnitudes, signs put back afterwards
            // the way C's truncating division does.
            S_DIV: begin
                div_neg_q <= div_sgn && (div_n0[63] ^ r_s[31]);
                div_neg_r <= div_sgn && div_n0[63];
                div_n <= (div_sgn && div_n0[63]) ? (64'd0 - div_n0) : div_n0;
                div_d <= (div_sgn && r_s[31])    ? (32'd0 - r_s)    : r_s;
                div_q <= '0; div_r <= '0; div_i <= 7'd64;
                state <= S_DIV2;
            end
            S_DIV2: begin
                if (div_i != 7'd0) begin
                    div_n <= {div_n[62:0], 1'b0};
                    if (div_rsh >= {33'd0, div_d}) begin
                        div_r <= div_rsh - {33'd0, div_d}; div_q <= {div_q[62:0], 1'b1};
                    end else begin
                        div_r <= div_rsh;                  div_q <= {div_q[62:0], 1'b0};
                    end
                    div_i <= div_i - 7'd1;
                end else begin
                    st[ST_V] <= 1'b0; st[ST_Z] <= 1'b0;
                    if (div_sgn) st[ST_N] <= 1'b0;
                    if ((kind == K_DIVS || kind == K_DIVU) && div_wide && div_ovf) begin
                        st[ST_V] <= 1'b1;
                    end else if (kind == K_MODS || kind == K_MODU) begin
                        `SET_REG(fR, rd, div_rem)
                        st[ST_Z] <= (div_rem == 32'd0);
                        if (kind == K_MODS) st[ST_N] <= div_rem[31];
                    end else begin
                        `SET_REG(fR, rd, div_qs[31:0])
                        if (div_wide) `SET_REG2(fR, rd | 4'd1, div_rem)
                        st[ST_Z] <= (div_qs[31:0] == 32'd0);
                        if (kind == K_DIVS) st[ST_N] <= div_qs[31];
                    end
                    state <= S_DONE;
                end
            end

            // ------------------------------------------------ PIXT and DRAV
            // pixt_m: 0 R,*R.XY  1 *R.XY,R  2 *R.XY,*R.XY  4 R,*R  5 *R,R  6 *R,*R
            S_PIX_RD: begin
                if (kind == K_DRAV || pixt_m == 3'd0 || pixt_m == 3'd4) begin
                    t_data <= (kind == K_DRAV) ? rb[9] : r_s;
                    state  <= S_PIX_WR;
                end else if (io_srt) begin
                    // a shift-register transfer: one read cycle, flagged, and
                    // whatever comes back is the "pixel", all 16 bits of it
                    t_a   <= (pixt_m == 3'd5 || pixt_m == 3'd6) ? r_s : xytol(r_s, io_convsp);
                    state <= S_PIX_SRT;
                end else begin
                    fe_addr <= ((pixt_m == 3'd5 || pixt_m == 3'd6) ? r_s
                                                                   : xytol(r_s, io_convsp))
                               & pix_amsk;
                    fe_size <= psize6; fe_wr <= 1'b0;
                    fe_ret <= S_PIX_WR; state <= S_FE;
                end
            end
            S_PIX_SRT: begin
                if (!q_req) begin
                    q_req <= 1'b1; bus_we <= 1'b0; bus_srt <= 1'b1; bus_addr <= t_a[31:4];
                end else if (q_ack) begin
                    q_req <= 1'b0; bus_srt <= 1'b0;
                    srt_val <= q_rdata;
                    state   <= S_PIX_WR;
                end
            end
            S_PIX_WR: begin
                if (kind != K_DRAV && (pixt_m == 3'd1 || pixt_m == 3'd5)) begin
                    // into a register: V says the pixel was not zero
                    `SET_REG(fR, rd, pix_val)
                    st[ST_V] <= (pix_val != 32'd0);
                    state <= S_DONE;
                end else if (io_srt) begin
                    // register-to-VRAM transfer: MAME's write_pixel_shiftreg
                    t_a   <= (kind == K_DRAV || pixt_m == 3'd0 || pixt_m == 3'd2)
                             ? xytol(r_d, io_convdp) : r_d;
                    state <= S_PIX_SRTW;
                end else if (io_control[5] && pix_val == 32'd0) begin
                    state <= S_PIX_END;              // transparent: nothing is written
                end else begin
                    fe_addr <= ((kind == K_DRAV || pixt_m == 3'd0 || pixt_m == 3'd2)
                                ? xytol(r_d, io_convdp) : r_d) & pix_amsk;
                    fe_size <= psize6; fe_wr <= 1'b1; fe_wdata <= pix_val;
                    fe_ret <= S_PIX_END; state <= S_FE;
                end
            end
            S_PIX_SRTW: begin
                if (!q_req) begin
                    q_req <= 1'b1; bus_we <= 1'b1; bus_srt <= 1'b1; bus_addr <= t_a[31:4];
                end else if (q_ack) begin
                    q_req <= 1'b0; bus_srt <= 1'b0;
                    state <= S_PIX_END;
                end
            end
            S_PIX_END: begin
                if (kind == K_DRAV)
                    `SET_REG(fR, rd, {r_d[31:16] + r_s[31:16], r_d[15:0] + r_s[15:0]})
                state <= S_DONE;
            end

            // ------------------------------------------------ PIXBLT B and FILL
            G_INIT: begin
                g_saddr <= rb[0]; g_daddr <= g_d0; g_dacc <= rb[2];
                g_y <= g_dy[15:0];
                if (g_fw0 < 0) begin g_lp <= g_dx[4:0]; g_rp <= 5'd0; g_fw <= 16'd0; end
                else begin g_lp <= g_lp0; g_rp <= g_rp0; g_fw <= 16'(g_fw0 >> (3'd4 - g_l2)); end
                // MAME's count (34010gfx.hxx): 4, 2 more for an XY destination,
                // 2 more once it is known not to be clipped away - and a
                // FILL or PIXBLT that is clipped away returns before any of
                // it is charged.  Then every row owes `g_rowcyc`.
                if (g_dx <= 0 || g_dy <= 0) state <= S_DONE;
                else begin
                    cyc_add <= g_xy ? 16'd8 : 16'd6; cyc_stb <= 1'b1;
                    state   <= G_ROW;
                end
            end
            G_ROW: begin
                g_dword <= g_daddr[31:4]; g_sword <= g_saddr[31:4]; g_sbit <= g_saddr[3:0];
                g_seg <= 2'd0; g_fwc <= g_fw;
                state <= g_fill ? G_SEG : G_ROWSRC;
            end
            G_ROWSRC, G_SRCRD: begin
                if (!q_req) begin
                    q_req <= 1'b1; bus_we <= 1'b0; bus_addr <= g_sword;
                end else if (q_ack) begin
                    q_req <= 1'b0; g_srcw <= q_rdata; g_sword <= g_sword + 28'd1;
                    state <= (state == G_ROWSRC) ? G_SEG
                           : (g_cnt == 5'd0)     ? G_WRDST : G_PIX;
                end
            end
            G_SEG: begin
                case (g_seg)
                    2'd0: if (g_lp != 5'd0) begin
                              g_cnt <= g_lp; g_dpos <= g_daddr[3:0]; state <= G_RDDST;
                          end else g_seg <= 2'd1;
                    2'd1: if (g_fwc != 16'd0) begin
                              g_cnt <= g_ppw; g_dpos <= 4'd0; g_dstw <= 16'd0;
                              // a full word is only read back when something of
                              // it may survive, which is when transparency is on
                              state <= io_control[5] ? G_RDDST : G_PIX;
                          end else g_seg <= 2'd2;
                    2'd2: if (g_rp != 5'd0) begin
                              g_cnt <= g_rp; g_dpos <= 4'd0; state <= G_RDDST;
                          end else state <= G_ROWEND;
                    default: state <= G_ROWEND;
                endcase
            end
            G_RDDST: begin
                if (!q_req) begin
                    q_req <= 1'b1; bus_we <= 1'b0; bus_addr <= g_dword; bus_srt <= io_srt;
                end else if (q_ack) begin
                    q_req <= 1'b0; bus_srt <= 1'b0; g_dstw <= q_rdata; state <= G_PIX;
                end
            end
            G_PIX: begin
                if (!g_keep) g_dstw <= (g_dstw & ~g_pmask) | g_pixel;
                g_cnt  <= g_cnt - 5'd1;
                g_dpos <= g_dpos + g_bpp[3:0];
                g_sbit <= g_sbit + 4'd1;
                if (!g_fill && g_sbit == 4'd15) state <= G_SRCRD;
                else if (g_cnt == 5'd1)         state <= G_WRDST;
            end
            G_WRDST: begin
                if (!q_req) begin
                    q_req <= 1'b1; bus_we <= 1'b1; bus_addr <= g_dword; bus_wdata <= g_dstw;
                    bus_srt <= io_srt;
                end else if (q_ack) begin
                    q_req <= 1'b0; bus_srt <= 1'b0; g_dword <= g_dword + 28'd1;
                    if (g_seg == 2'd0)      g_seg <= 2'd1;
                    else if (g_seg == 2'd1) g_fwc <= g_fwc - 16'd1;
                    state <= (g_seg == 2'd2) ? G_ROWEND : G_SEG;
                end
            end
            G_ROWEND: begin
                g_saddr <= g_saddr + rb[1]; g_daddr <= g_daddr + rb[3]; g_dacc <= g_dacc + rb[3];
                g_y <= g_y - 16'd1;
                cyc_add <= g_rowcyc; cyc_stb <= 1'b1;
                state <= (g_y == 16'd1) ? G_FIN : G_ROW;
            end
            G_FIN: begin
                if (!g_fill) rb[0] <= g_saddr;
                if (g_xy) rb[2][31:16] <= rb[2][31:16] + rb[7][31:16];
                else      rb[2] <= g_dacc;
                state <= S_DONE;
            end

            // ------------------------------------------------ the field engine
            S_FE: begin
                fe_step <= 4'd0;
                fe_w[0] <= '0; fe_w[1] <= '0; fe_w[2] <= '0; fe_w[3] <= '0;
                state   <= S_FE_BUS;
            end
            S_FE_BUS: begin
                if (!fe_now[3]) begin
                    state <= fe_ret;
                end else if (!q_req) begin
                    q_req   <= 1'b1;
                    bus_we    <= fe_now[2];
                    bus_addr  <= fe_base + {26'd0, fe_now[1:0]};
                    bus_wdata <= fe_new[16 * fe_now[1:0] +: 16];
                end else if (q_ack) begin
                    q_req <= 1'b0;
                    if (!fe_now[2]) begin
                        // a read of one of the CPU's own I/O registers comes
                        // from the CPU, whatever the bus says
                        fe_w[fe_now[1:0]] <= (!io_hit || IO_READ_FROM_BUS) ? q_rdata
                                           : (io_reg == IO_INTENB)  ? io_intenb
                                           : (io_reg == IO_INTPEND) ? io_intpend
                                           : (io_reg == IO_CONTROL) ? io_control
                                           : (io_reg == IO_CONVSP)  ? io_convsp
                                           : (io_reg == IO_CONVDP)  ? io_convdp
                                           : (io_reg == IO_PSIZE)   ? io_psize
                                           : (io_reg == IO_PMASK)   ? io_pmask
                                           :                          q_rdata;
                    end else if (io_hit) begin
                        case (io_reg)
                            IO_DPYCTL:  io_srt     <= bus_wdata[11];
                            IO_CONTROL: io_control <= bus_wdata;
                            IO_CONVSP:  io_convsp  <= bus_wdata;
                            IO_CONVDP:  io_convdp  <= bus_wdata;
                            IO_PSIZE:   io_psize   <= bus_wdata;
                            IO_PMASK:   io_pmask   <= bus_wdata;
                            IO_INTENB:  io_intenb  <= bus_wdata;
                            // only DI and WV can be cleared, and only by a 0
                            IO_INTPEND: begin
                                if (!bus_wdata[10]) io_intpend[10] <= 1'b0;
                                if (!bus_wdata[11]) io_intpend[11] <= 1'b0;
                            end
                            default: ;
                        endcase
                    end
                    fe_step <= fe_step + 4'd1;
                end
            end

            // ------------------------------------------------ pace
            // ...and, the moment nothing is owed, begin the next instruction
            // here rather than spend a step getting to S_FETCH to do it
            S_DONE: begin
                push_st_too <= 1'b0;
                ext_seen <= 1'b0;
                if (bal <= 28'sd0) begin
                    if (irq_any) state <= S_IRQ;
                    else begin
                        insn_start_q <= 1'b1;
                        q_req <= 1'b1; bus_we <= 1'b0; bus_addr <= pc[31:4];
                        state <= S_DECODE;
                    end
                end
            end
            default: state <= S_RESET;
        endcase

        // the register file's two write ports
        if (!rst_q && w_en) begin
            if (w_i == 4'd15) sp <= w_v;
            else if (w_f)     rb[w_i] <= w_v;
            else              ra[w_i] <= w_v;
        end
        if (!rst_q && w2_en) begin
            if (w2_i == 4'd15) sp <= w2_v;
            else if (w2_f)     rb[w2_i] <= w2_v;
            else               ra[w2_i] <= w2_v;
        end
    end
    /* verilator lint_on BLKSEQ */

    // ------------------------------------------------ what sees every clock
    // `step`; the bus handshake (an ack is a one-clock pulse and may come on
    // any clock: it is latched with its data, the request to the outside
    // drops at once so the far side does not take it for a second one, and
    // the machine picks both up at its next step); the display interrupt's
    // pulse, held for the machine the same way; the cycle account, which has
    // to count every `cen`; and the two pulses for the benches, cut to one
    // clock each.
    always_ff @(posedge clk) begin
        if (rst_q) begin
            stepcnt <= '0; q_ack <= 1'b0; dpy_l <= 1'b0; bal <= '0; cyc_total <= '0;
        end else begin
            stepcnt <= step ? 2'd0 : (stepcnt == 2'(STEP - 1)) ? stepcnt : stepcnt + 2'd1;
            if (bus_req && bus_ack) begin q_ack <= 1'b1; q_rdata <= bus_rdata; end
            else if (step)          q_ack <= 1'b0;      // the machine has seen it
            if (dpyint)    dpy_l <= 1'b1;
            else if (step) dpy_l <= 1'b0;
            // a charge is added once, on the step that ends the period it was up for
            if (step && cyc_stb) cyc_total <= cyc_total + {16'd0, cyc_add};
            bal <= bal + ((step && cyc_stb) ? $signed({12'd0, cyc_add}) : 28'sd0)
                       - ((cen && bal > CREDIT) ? 28'sd1 : 28'sd0);
        end
    end
    assign bus_req    = q_req && !q_ack;
    assign insn_start = insn_start_q && first;
    assign irq_taken  = irq_taken_q  && first;

    wire _unused = &{1'b0, mul_p[65:64], 1'b0};
endmodule

`undef SET_REG
`undef SET_REG2
`default_nettype wire
