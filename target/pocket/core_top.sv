//------------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2023, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// Copyright (c) 2023, Marcus Andrade <marcus@opengateware.org>
// Copyright (c) 2022, Analogue Enterprises Limited
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
//------------------------------------------------------------------------------
// Platform Specific top-level -- NBA Jam
// Instantiated by the real top-level: apf_top
//
// The machine (rtl/nbajam_core.sv) is platform-agnostic; this file is the APF
// glue: bridge, the ROM slot, the interact menu, video and audio hand-off, the
// memories, and the bring-up panel.  The ROM image lives in SDRAM and the
// tilemap RAM in the SRAM (target/pocket/nbajam_mem.sv).
//
// Everything above the "@ The game" banner is the framework's and is the same
// in every core here.  Below it, the shapes are proven on hardware -- the
// reset chain, the SRAM self-test, the pause, the clock-domain hand-overs --
// and the contents are yours.  Read METHODOLOGY.md sections 5.4, 5.5, 5.8 and
// 5.16 to 5.21 before changing a shape.
//------------------------------------------------------------------------------

`default_nettype none

module core_top
    #(
         //! ------------------------------------------------------------------------
         //! System Configuration Parameters
         //! ------------------------------------------------------------------------
         // Memory
         parameter USE_SDRAM    = 1,       //! Enable SDRAM (the whole ROM image)
         parameter USE_SRAM     = 1,       //! Enable SRAM (tilemap VRAM)
         parameter USE_CRAM0    = 0,       //! Cellular RAM #1: unused
         parameter USE_CRAM1    = 0,       //! Cellular RAM #2: unused
         // Video
         parameter BPP_R        = 8,       //! Bits Per Pixel Red
         parameter BPP_G        = 8,       //! Bits Per Pixel Green
         parameter BPP_B        = 8,       //! Bits Per Pixel Blue
         // Audio
         parameter AUDIO_DW     = 16,      //! Audio Bits
         parameter AUDIO_S      = 1,       //! Signed Audio
         parameter STEREO       = 1,       //! Stereo Output
         parameter AUDIO_MIX    = 0,       //! [0] No Mix | [1] 25% | [2] 50% | [3] 100% (mono)
         // Gamepad/Joystick
         parameter JOY_PADS     = 2,       //! Total Number of Gamepads
         parameter JOY_ALT      = 0,       //! 2 Players Alternate
         // Data I/O - [MPU -> FPGA]
         parameter DIO_MASK     = 4'h0,    //! Upper 4 bits of address
         parameter DIO_AW       = 27,      //! Address Width
         parameter DIO_DW       = 8,       //! Data Width (8 or 16 bits)
         parameter DIO_DELAY    = 7,       //! Number of clock cycles to delay each write output
         parameter DIO_HOLD     = 4,       //! Number of clock cycles to hold the ioctl_wr signal high
         // HiScore I/O - [MPU <-> FPGA]
         parameter HS_AW        = 16,      //! Max size of game RAM address for highscores
         parameter HS_SW        = 8,       //! Max size of capture RAM For highscore data (default 8 = 256 bytes max)
         parameter HS_CFG_AW    = 2,       //! Max size of RAM address for highscore.dat entries (default 4 = 16 entries max)
         parameter HS_CFG_LW    = 2,       //! Max size of length for each highscore.dat entries (default 1 = 256 bytes max)
         parameter HS_CONFIG    = 2,       //! Dataslot index for config transfer
         parameter HS_DATA      = 3,       //! Dataslot index for save data transfer
         parameter HS_NVM_SZ    = 32'd93,  //! Number bytes required for Save
         parameter HS_MASK      = 4'h1,    //! Upper 4 bits of address
         parameter HS_WR_DELAY  = 4,       //! Number of clock cycles to delay each write output
         parameter HS_WR_HOLD   = 1,       //! Number of clock cycles to hold the nvram_wr signal high
         parameter HS_RD_DELAY  = 4,       //! Number of clock cycles it takes for a read to complete
         // Save I/O - [MPU <-> FPGA]
         parameter SIO_MASK     = 4'h1,    //! Upper 4 bits of address
         parameter SIO_AW       = 27,      //! Address Width
         parameter SIO_DW       = 8,       //! Data Width (8 or 16 bits)
         parameter SIO_WR_DELAY = 4,       //! Number of clock cycles to delay each write output
         parameter SIO_WR_HOLD  = 1,       //! Number of clock cycles to hold the nvram_wr signal high
         parameter SIO_RD_DELAY = 4,       //! Number of clock cycles it takes for a read to complete
         parameter SIO_SAVE_IDX = 2        //! Dataslot index for save data transfer
     ) (
         //! --------------------------------------------------------------------
         //! Clock Inputs 74.25mhz.
         //! Not Phase Aligned, Treat These Domains as Asynchronous
         //! --------------------------------------------------------------------
         input wire          clk_74a, // mainclk1
         input wire          clk_74b, // mainclk1

         //! --------------------------------------------------------------------
         //! Cartridge Interface
         //! --------------------------------------------------------------------
         inout  wire   [7:0] cart_tran_bank2,
         output wire         cart_tran_bank2_dir,
         inout  wire   [7:0] cart_tran_bank3,
         output wire         cart_tran_bank3_dir,
         inout  wire   [7:0] cart_tran_bank1,
         output wire         cart_tran_bank1_dir,
         inout  wire   [7:4] cart_tran_bank0,
         output wire         cart_tran_bank0_dir,
         inout  wire         cart_tran_pin30,
         output wire         cart_tran_pin30_dir,
         output wire         cart_pin30_pwroff_reset,
         inout  wire         cart_tran_pin31,
         output wire         cart_tran_pin31_dir,

         //! --------------------------------------------------------------------
         //! Infrared
         //! --------------------------------------------------------------------
         input  wire         port_ir_rx,
         output wire         port_ir_tx,
         output wire         port_ir_rx_disable,

         //! --------------------------------------------------------------------
         //! GBA link port
         //! --------------------------------------------------------------------
         inout  wire         port_tran_si,
         output wire         port_tran_si_dir,
         inout  wire         port_tran_so,
         output wire         port_tran_so_dir,
         inout  wire         port_tran_sck,
         output wire         port_tran_sck_dir,
         inout  wire         port_tran_sd,
         output wire         port_tran_sd_dir,

         //! --------------------------------------------------------------------
         //! Cellular PSRAM 0 and 1, two chips (64mbit x2 dual die per chip)
         //! --------------------------------------------------------------------
         output wire [21:16] cram0_a,
         inout  wire  [15:0] cram0_dq,
         input  wire         cram0_wait,
         output wire         cram0_clk,
         output wire         cram0_adv_n,
         output wire         cram0_cre,
         output wire         cram0_ce0_n,
         output wire         cram0_ce1_n,
         output wire         cram0_oe_n,
         output wire         cram0_we_n,
         output wire         cram0_ub_n,
         output wire         cram0_lb_n,

         output wire [21:16] cram1_a,
         inout  wire  [15:0] cram1_dq,
         input  wire         cram1_wait,
         output wire         cram1_clk,
         output wire         cram1_adv_n,
         output wire         cram1_cre,
         output wire         cram1_ce0_n,
         output wire         cram1_ce1_n,
         output wire         cram1_oe_n,
         output wire         cram1_we_n,
         output wire         cram1_ub_n,
         output wire         cram1_lb_n,

         //! --------------------------------------------------------------------
         //! SDRAM, 512mbit 16bit
         //! --------------------------------------------------------------------
         output wire  [12:0] dram_a,        // Address bus
         output wire   [1:0] dram_ba,       // Bank select (single bits)
         inout  wire  [15:0] dram_dq,       // Bidirectional data bus
         output wire   [1:0] dram_dqm,      // High/low byte mask
         output wire         dram_clk,      // Chip clock
         output wire         dram_cke,      // Clock enable
         output wire         dram_ras_n,    // Select row address (active low)
         output wire         dram_cas_n,    // Select column address (active low)
         output wire         dram_we_n,     // Write enable (active low)

         //! --------------------------------------------------------------------
         //! SRAM, 1mbit 16bit
         //! --------------------------------------------------------------------
         output wire  [16:0] sram_a,        // Address bus
         inout  wire  [15:0] sram_dq,       // Bidirectional data bus
         output wire         sram_oe_n,     // Output enable
         output wire         sram_we_n,     // Write enable
         output wire         sram_ub_n,     // Upper Byte Mask
         output wire         sram_lb_n,     // Lower Byte Mask

         //! --------------------------------------------------------------------
         //! vblank driven by dock for sync in a certain mode
         //! --------------------------------------------------------------------
         input  wire         vblank,

         //! --------------------------------------------------------------------
         //! I/O to 6515D breakout USB UART
         //! --------------------------------------------------------------------
         output wire         dbg_tx,
         input  wire         dbg_rx,

         //! --------------------------------------------------------------------
         //! I/O pads near jtag connector user can solder to
         //! --------------------------------------------------------------------
         output wire         user1,
         input  wire         user2,

         //! --------------------------------------------------------------------
         //! RFU internal i2c bus
         //! --------------------------------------------------------------------
         inout  wire         aux_sda,
         output wire         aux_scl,

         //! --------------------------------------------------------------------
         //! RFU, do not use !!!
         //! --------------------------------------------------------------------
         output wire         vpll_feed,

         //! --------------------------------------------------------------------
         //! Video Output to Scaler
         //! --------------------------------------------------------------------
         output wire  [23:0] video_rgb,
         output wire         video_rgb_clock,
         output wire         video_rgb_clock_90,
         output wire         video_hs,
         output wire         video_vs,
         output wire         video_de,
         output wire         video_skip,

         //! --------------------------------------------------------------------
         //! Audio
         //! --------------------------------------------------------------------
         output wire         audio_mclk,
         output wire         audio_lrck,
         output wire         audio_dac,
         input  wire         audio_adc,

         //! --------------------------------------------------------------------
         //! Bridge Bus Connection (synchronous to clk_74a)
         //! --------------------------------------------------------------------
         output wire         bridge_endian_little,
         input  wire  [31:0] bridge_addr,
         input  wire         bridge_rd,
         output reg   [31:0] bridge_rd_data,
         input  wire         bridge_wr,
         input  wire  [31:0] bridge_wr_data,

         //! --------------------------------------------------------------------
         //! Controller Data
         //! --------------------------------------------------------------------
         input  wire  [31:0] cont1_key,
         input  wire  [31:0] cont2_key,
         input  wire  [31:0] cont3_key,
         input  wire  [31:0] cont4_key,
         input  wire  [31:0] cont1_joy,
         input  wire  [31:0] cont2_joy,
         input  wire  [31:0] cont3_joy,
         input  wire  [31:0] cont4_joy,
         input  wire  [15:0] cont1_trig,
         input  wire  [15:0] cont2_trig,
         input  wire  [15:0] cont3_trig,
         input  wire  [15:0] cont4_trig
     );

    // not using the IR port, so turn off both the LED, and
    // disable the receive circuit to save power
    assign port_ir_tx         = 0;
    assign port_ir_rx_disable = 1;

    // bridge endianness
    assign bridge_endian_little = 0;

    // cart is unused, so set all level translators accordingly
    // directions are 0:IN, 1:OUT
    assign cart_tran_bank3         = 8'hzz;
    assign cart_tran_bank3_dir     = 1'b0;
    assign cart_tran_bank2         = 8'hzz;
    assign cart_tran_bank2_dir     = 1'b0;
    assign cart_tran_bank1         = 8'hzz;
    assign cart_tran_bank1_dir     = 1'b0;
    assign cart_tran_bank0         = 4'hf;
    assign cart_tran_bank0_dir     = 1'b1;
    assign cart_tran_pin30         = 1'b0;  // reset or cs2, we let the hw control it by itself
    assign cart_tran_pin30_dir     = 1'bz;
    assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
    assign cart_tran_pin31         = 1'bz;  // input
    assign cart_tran_pin31_dir     = 1'b0;  // input

    // link port is input only
    assign port_tran_so      = 1'bz;
    assign port_tran_so_dir  = 1'b0; // SO is output only
    assign port_tran_si      = 1'bz;
    assign port_tran_si_dir  = 1'b0; // SI is input only
    assign port_tran_sck     = 1'bz;
    assign port_tran_sck_dir = 1'b0; // clock direction can change
    assign port_tran_sd      = 1'bz;
    assign port_tran_sd_dir  = 1'b0; // SD is input and not used

    assign video_skip = 1'b0;

    assign dbg_tx    = 1'bZ;
    assign user1     = 1'bZ;
    assign aux_scl   = 1'bZ;
    assign vpll_feed = 1'bZ;

    // Tie off the memory the pins not being used
    generate
        if(USE_CRAM0 == 0) begin
            assign cram0_a     = 'h0;
            assign cram0_dq    = {16{1'bZ}};
            assign cram0_clk   = 0;
            assign cram0_adv_n = 1;
            assign cram0_cre   = 0;
            assign cram0_ce0_n = 1;
            assign cram0_ce1_n = 1;
            assign cram0_oe_n  = 1;
            assign cram0_we_n  = 1;
            assign cram0_ub_n  = 1;
            assign cram0_lb_n  = 1;
        end
        if(USE_CRAM1 == 0) begin
            assign cram1_a     = 'h0;
            assign cram1_dq    = {16{1'bZ}};
            assign cram1_clk   = 0;
            assign cram1_adv_n = 1;
            assign cram1_cre   = 0;
            assign cram1_ce0_n = 1;
            assign cram1_ce1_n = 1;
            assign cram1_oe_n  = 1;
            assign cram1_we_n  = 1;
            assign cram1_ub_n  = 1;
            assign cram1_lb_n  = 1;
        end
        if(USE_SDRAM == 0) begin
            assign dram_a     = 'h0;
            assign dram_ba    = 'h0;
            assign dram_dq    = {16{1'bZ}};
            assign dram_dqm   = 'h0;
            assign dram_clk   = 'h0;
            assign dram_cke   = 'h0;
            assign dram_ras_n = 'h1;
            assign dram_cas_n = 'h1;
            assign dram_we_n  = 'h1;
        end
        if(USE_SRAM == 0) begin
            assign sram_a    = 'h0;
            assign sram_dq   = {16{1'bZ}};
            assign sram_oe_n = 1;
            assign sram_we_n = 1;
            assign sram_ub_n = 1;
            assign sram_lb_n = 1;
        end
    endgenerate

    //! ------------------------------------------------------------------------
    //! Host/Target Command Handler
    //! ------------------------------------------------------------------------
    wire        reset_n;  // driven by host commands, can be used as core-wide reset
    wire [31:0] cmd_bridge_rd_data;

    // bridge host commands
    // synchronous to clk_74a
    wire        status_boot_done  = pll_core_locked_s;
    wire        status_setup_done = pll_core_locked_s; // rising edge triggers a target command
    wire        status_running    = reset_n;           // we are running as soon as reset_n goes high

    wire        dataslot_requestread;
    wire [15:0] dataslot_requestread_id;
    wire        dataslot_requestread_ack = 1;
    wire        dataslot_requestread_ok  = 1;

    wire        dataslot_requestwrite;
    wire [15:0] dataslot_requestwrite_id;
    wire [31:0] dataslot_requestwrite_size;
    wire        dataslot_requestwrite_ack = 1;
    wire        dataslot_requestwrite_ok  = 1;

    wire        dataslot_update;
    wire [15:0] dataslot_update_id;
    wire [31:0] dataslot_update_size;

    wire        dataslot_allcomplete;

    wire [31:0] rtc_epoch_seconds;
    wire [31:0] rtc_date_bcd;
    wire [31:0] rtc_time_bcd;
    wire        rtc_valid;

    wire        savestate_supported;
    wire [31:0] savestate_addr;
    wire [31:0] savestate_size;
    wire [31:0] savestate_maxloadsize;

    wire        savestate_start;
    wire        savestate_start_ack;
    wire        savestate_start_busy;
    wire        savestate_start_ok;
    wire        savestate_start_err;

    wire        savestate_load;
    wire        savestate_load_ack;
    wire        savestate_load_busy;
    wire        savestate_load_ok;
    wire        savestate_load_err;

    wire        osnotify_inmenu;

    // bridge target commands
    // synchronous to clk_74a
    reg         target_dataslot_read;
    reg         target_dataslot_write;
    reg         target_dataslot_getfile;    // require additional param/resp structs to be mapped
    reg         target_dataslot_openfile;   // require additional param/resp structs to be mapped

    wire        target_dataslot_ack;
    wire        target_dataslot_done;
    wire  [2:0] target_dataslot_err;

    reg  [15:0] target_dataslot_id;
    reg  [31:0] target_dataslot_slotoffset;
    reg  [31:0] target_dataslot_bridgeaddr;
    reg  [31:0] target_dataslot_length;

    wire [31:0] target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire [31:0] target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands

    // bridge data slot access
    // synchronous to clk_74a
    logic  [9:0] datatable_addr;
    logic        datatable_wren;
    logic [31:0] datatable_data;
    wire  [31:0] datatable_q;

    // the save slot's size for the APF, written continuously as the NES core
    // does (slot index 2 -> size entry 2*2+1): the 16 KB CMOS.  Slot 0 is the
    // game's instance JSON, 1 the ROM, 2 the save (data.json).
    localparam [31:0] NV_BYTES = 32'h4000;
    always_ff @(posedge clk_74a) begin
        datatable_wren <= 1'b1;
        datatable_addr <= 10'd5;
        datatable_data <= NV_BYTES;
    end

    core_bridge_cmd icb
    (
        .clk                        ( clk_74a                    ),
        .reset_n                    ( reset_n                    ),

        .bridge_endian_little       ( bridge_endian_little       ),
        .bridge_addr                ( bridge_addr                ),
        .bridge_rd                  ( bridge_rd                  ),
        .bridge_rd_data             ( cmd_bridge_rd_data         ),
        .bridge_wr                  ( bridge_wr                  ),
        .bridge_wr_data             ( bridge_wr_data             ),

        .status_boot_done           ( status_boot_done           ),
        .status_setup_done          ( status_setup_done          ),
        .status_running             ( status_running             ),

        .dataslot_requestread       ( dataslot_requestread       ),
        .dataslot_requestread_id    ( dataslot_requestread_id    ),
        .dataslot_requestread_ack   ( dataslot_requestread_ack   ),
        .dataslot_requestread_ok    ( dataslot_requestread_ok    ),

        .dataslot_requestwrite      ( dataslot_requestwrite      ),
        .dataslot_requestwrite_id   ( dataslot_requestwrite_id   ),
        .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
        .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack  ),
        .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok   ),

        .dataslot_update            ( dataslot_update            ),
        .dataslot_update_id         ( dataslot_update_id         ),
        .dataslot_update_size       ( dataslot_update_size       ),

        .dataslot_allcomplete       ( dataslot_allcomplete       ),

        .rtc_epoch_seconds          ( rtc_epoch_seconds          ),
        .rtc_date_bcd               ( rtc_date_bcd               ),
        .rtc_time_bcd               ( rtc_time_bcd               ),
        .rtc_valid                  ( rtc_valid                  ),

        .savestate_supported        ( savestate_supported        ),
        .savestate_addr             ( savestate_addr             ),
        .savestate_size             ( savestate_size             ),
        .savestate_maxloadsize      ( savestate_maxloadsize      ),

        .savestate_start            ( savestate_start            ),
        .savestate_start_ack        ( savestate_start_ack        ),
        .savestate_start_busy       ( savestate_start_busy       ),
        .savestate_start_ok         ( savestate_start_ok         ),
        .savestate_start_err        ( savestate_start_err        ),

        .savestate_load             ( savestate_load             ),
        .savestate_load_ack         ( savestate_load_ack         ),
        .savestate_load_busy        ( savestate_load_busy        ),
        .savestate_load_ok          ( savestate_load_ok          ),
        .savestate_load_err         ( savestate_load_err         ),

        .osnotify_inmenu            ( osnotify_inmenu            ),

        .target_dataslot_read       ( target_dataslot_read       ),
        .target_dataslot_write      ( target_dataslot_write      ),
        .target_dataslot_getfile    ( target_dataslot_getfile    ),
        .target_dataslot_openfile   ( target_dataslot_openfile   ),

        .target_dataslot_ack        ( target_dataslot_ack        ),
        .target_dataslot_done       ( target_dataslot_done       ),
        .target_dataslot_err        ( target_dataslot_err        ),

        .target_dataslot_id         ( target_dataslot_id         ),
        .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
        .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
        .target_dataslot_length     ( target_dataslot_length     ),

        .target_buffer_param_struct ( target_buffer_param_struct ),
        .target_buffer_resp_struct  ( target_buffer_resp_struct  ),

        .datatable_addr             ( datatable_addr             ),
        .datatable_wren             ( datatable_wren             ),
        .datatable_data             ( datatable_data             ),
        .datatable_q                ( datatable_q                )
    );

    //! END OF APF /////////////////////////////////////////////////////////////

    //! ////////////////////////////////////////////////////////////////////////
    //! @ System Modules
    //! ////////////////////////////////////////////////////////////////////////

    //! ------------------------------------------------------------------------
    //! APF Bridge Read Data
    //! ------------------------------------------------------------------------
    wire [31:0] int_bridge_rd_data;
    wire [31:0] nvm_bridge_rd_data_s;
    always_comb begin
        casex(bridge_addr)
            32'h2xxxxxxx: begin bridge_rd_data <= nvm_bridge_rd_data_s; end // the save slot
            32'hF0000000: begin bridge_rd_data <= int_bridge_rd_data;   end // Reset
            32'hF0000010: begin bridge_rd_data <= int_bridge_rd_data;   end // Service Mode Switch
            32'hF1000000: begin bridge_rd_data <= int_bridge_rd_data;   end // DIP Switches
            32'hF2000000: begin bridge_rd_data <= int_bridge_rd_data;   end // Modifiers
            32'hF3000000: begin bridge_rd_data <= int_bridge_rd_data;   end // A/V Filters
            32'hF4000000: begin bridge_rd_data <= int_bridge_rd_data;   end // Extra DIP Switches
            32'hF8xxxxxx: begin bridge_rd_data <= cmd_bridge_rd_data;   end // APF Bridge (Reserved)
            32'hFA000000: begin bridge_rd_data <= int_bridge_rd_data;   end // Status Low  [31:0]
            32'hFB000000: begin bridge_rd_data <= int_bridge_rd_data;   end // Status High [63:32]
            default:      begin bridge_rd_data <= 0;                    end
        endcase
    end

    //! ------------------------------------------------------------------------
    //! Pause Core (Analogue OS Menu/Module Request)
    //! ------------------------------------------------------------------------
    wire pause_core, pause_req;
    pause_crtl core_pause
    (
        .clk_sys    ( clk_sys         ),
        .os_inmenu  ( osnotify_inmenu ),
        .pause_req  ( pause_req       ),
        .pause_core ( pause_core      )
    );

    //! ------------------------------------------------------------------------
    //! Interact: Dip Switches, Modifiers, Filters and Reset
    //! ------------------------------------------------------------------------
    wire  [7:0] dip_sw0, dip_sw1, dip_sw2, dip_sw3;
    wire  [7:0] ext_sw0, ext_sw1, ext_sw2, ext_sw3;
    wire  [7:0] mod_sw0, mod_sw1, mod_sw2, mod_sw3;
    wire  [3:0] scnl_sw, smask_sw, afilter_sw, vol_att;
    wire [63:0] status;
    wire        reset_sw, svc_sw, nvclear_sw;

    interact pocket_interact
    (
        // Clocks and Reset
        .clk_74a          ( clk_74a            ),
        .clk_sync         ( clk_sys            ),
        .reset_n          ( reset_n            ),
        // Pocket Bridge
        .bridge_addr      ( bridge_addr        ),
        .bridge_wr        ( bridge_wr          ),
        .bridge_wr_data   ( bridge_wr_data     ),
        .bridge_rd        ( bridge_rd          ),
        .bridge_rd_data   ( int_bridge_rd_data ),
        // Service Mode Switch
        .svc_sw           ( svc_sw             ),
        // DIP Switches
        .dip_sw0          ( dip_sw0            ),
        .dip_sw1          ( dip_sw1            ),
        .dip_sw2          ( dip_sw2            ),
        .dip_sw3          ( dip_sw3            ),
        // Extra DIP Switches
        .ext_sw0          ( ext_sw0            ),
        .ext_sw1          ( ext_sw1            ),
        .ext_sw2          ( ext_sw2            ),
        .ext_sw3          ( ext_sw3            ),
        // Modifiers
        .mod_sw0          ( mod_sw0            ),
        .mod_sw1          ( mod_sw1            ),
        .mod_sw2          ( mod_sw2            ),
        .mod_sw3          ( mod_sw3            ),
        // Status (Legacy Support)
        .status           ( status             ),
        // Filters Switches
        .scnl_sw          ( scnl_sw            ),
        .smask_sw         ( smask_sw           ),
        .afilter_sw       ( afilter_sw         ),
        .vol_att          ( vol_att            ),
        // Reset Switch
        .reset_sw         ( reset_sw           ),
        .nvclear_sw       ( nvclear_sw         )
    );

    //! ------------------------------------------------------------------------
    //! The CMOS save (data.json slot 1: 16 KB at bridge address 0x20000000).
    //! STUN Runner's, which it took hardware bisection to get right:
    //!  * not 0x10000000 -- a slot there hung the Pocket at the end of loading;
    //!  * the slot's size comes from the core's data table (entry 3, above);
    //!  * the Pocket only writes back a nonvolatile slot it loaded, so a first
    //!    save would never be made: the core itself commands the write, two
    //!    seconds after the game last wrote its CMOS, at once when the menu
    //!    opens, and once five seconds after loading.
    //! The file is the CMOS as MAME keeps it, 8K little-endian words, so a
    //! MAME nbajam.nv and this file are the same thing.
    //! ------------------------------------------------------------------------
    wire        nv_dl_download, nv_dl_wr;
    wire [13:0] nv_dl_addr;
    wire  [7:0] nv_dl_data;
    wire [15:0] nv_dl_index;
    data_io #(.MASK(4'h2), .AW(14), .DW(8), .DELAY(DIO_DELAY), .HOLD(DIO_HOLD)) pocket_nv_io
    (
        .clk_74a(clk_74a), .clk_memory(clk_sys),
        .dataslot_requestwrite(dataslot_requestwrite), .dataslot_requestwrite_id(dataslot_requestwrite_id),
        .dataslot_allcomplete(dataslot_allcomplete),
        .bridge_endian_little(bridge_endian_little), .bridge_addr(bridge_addr),
        .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .ioctl_download(nv_dl_download), .ioctl_index(nv_dl_index), .ioctl_wr(nv_dl_wr),
        .ioctl_addr(nv_dl_addr), .ioctl_data(nv_dl_data)
    );
    wire        nv_rd_en;
    wire [13:0] nv_rd_addr;
    wire  [7:0] nv_rd_data;
    data_unloader #(.ADDRESS_MASK_UPPER_4(4'h2), .ADDRESS_SIZE(14), .READ_MEM_CLOCK_DELAY(4), .INPUT_WORD_SIZE(1)) pocket_nv_unload
    (
        .clk_74a(clk_74a), .clk_memory(clk_sys),
        .bridge_rd(bridge_rd), .bridge_endian_little(bridge_endian_little), .bridge_addr(bridge_addr),
        .bridge_rd_data(nvm_bridge_rd_data_s),
        .read_en(nv_rd_en), .read_addr(nv_rd_addr), .read_data(nv_rd_data)
    );
    wire        po_nv_dirty;                // toggles on every CMOS write the game makes
    wire        nv_dirty_s;
    synch_3 sync_nvd(po_nv_dirty, nv_dirty_s, clk_74a);
    wire        inmenu_s;
    synch_3 sync_inmenu(osnotify_inmenu, inmenu_s, clk_74a);
    reg         nv_dirty_d = 1'b0, inmenu_d = 1'b0;
    reg         nv_pending = 1'b0;
    reg  [27:0] nv_timer   = 28'd0;
    reg  [1:0]  nv_state   = 2'd0;
    reg  [28:0] boot_timer = 29'd0;
    // dataslot_allcomplete cannot gate the saves (the bridge clears it when the
    // APF reads the slot for OUR write): latch its first rising edge instead
    reg         nv_loaded  = 1'b0;
    localparam  NV_SETTLE  = 28'd148_500_000;   // 2 s at 74.25 MHz
    localparam  NV_BOOT    = 29'd371_250_000;   // 5 s: one save after loading regardless
    always_ff @(posedge clk_74a) begin
        nv_dirty_d <= nv_dirty_s; inmenu_d <= inmenu_s;
        target_dataslot_read     <= 1'b0;
        target_dataslot_getfile  <= 1'b0;
        target_dataslot_openfile <= 1'b0;
        target_dataslot_id         <= 16'd2;
        target_dataslot_slotoffset <= 32'd0;
        target_dataslot_bridgeaddr <= 32'h2000_0000;
        target_dataslot_length     <= NV_BYTES;
        if (dataslot_allcomplete) nv_loaded <= 1'b1;
        if (nv_loaded && boot_timer != NV_BOOT) boot_timer <= boot_timer + 29'd1;
        if (nv_dirty_s != nv_dirty_d) begin nv_pending <= 1'b1; nv_timer <= 28'd0; end
        else if (nv_timer != NV_SETTLE) nv_timer <= nv_timer + 28'd1;
        case (nv_state)
            2'd0: begin
                target_dataslot_write <= 1'b0;
                if ((nv_pending && nv_loaded && (nv_timer == NV_SETTLE || (inmenu_s && !inmenu_d)))
                    || (boot_timer == NV_BOOT - 29'd1)) begin
                    target_dataslot_write <= 1'b1;      // rising edge starts the command
                    nv_pending <= 1'b0;
                    nv_state   <= 2'd1;
                end
            end
            2'd1: if (target_dataslot_ack) begin target_dataslot_write <= 1'b0; nv_state <= 2'd2; end
            2'd2: if (target_dataslot_done) nv_state <= 2'd0;
            default: nv_state <= 2'd0;
        endcase
    end
    // The CMOS's second port, in words: a loaded byte pair is written as one
    // little-endian word (even byte low), and the unloader's byte is picked
    // out of the word it addresses.
    logic  [7:0] nv_lo;
    logic        po_nv_we;
    logic [12:0] po_nv_waddr;
    logic [15:0] po_nv_wdata;
    wire  [15:0] po_nv_rdata;
    logic        nv_rd_hi;
    always_ff @(posedge clk_sys) begin
        po_nv_we <= 1'b0;
        if (nv_dl_download && nv_dl_index == 16'h2 && nv_dl_wr) begin   // the save is slot 2 (0 the game's JSON, 1 the ROM)
            if (!nv_dl_addr[0]) nv_lo <= nv_dl_data;
            else begin po_nv_we <= 1'b1; po_nv_waddr <= nv_dl_addr[13:1]; po_nv_wdata <= {nv_dl_data, nv_lo}; end
        end
        nv_rd_hi <= nv_rd_addr[0];
    end
    wire [12:0] po_nv_addr = po_nv_we ? po_nv_waddr : nv_rd_addr[13:1];
    assign nv_rd_data = nv_rd_hi ? po_nv_rdata[15:8] : po_nv_rdata[7:0];
    wire _nv_unused = &{1'b0, nv_rd_en};

    //! ------------------------------------------------------------------------
    //! Audio
    //! ------------------------------------------------------------------------
    wire [AUDIO_DW-1:0] core_snd_l, core_snd_r; // Audio Mono/Left/Right

    audio_mixer #(.DW(AUDIO_DW),.STEREO(STEREO),.IIR(0)) pocket_audio_mixer
    (
        // Clocks and Reset
        .clk_74b    ( clk_74b    ),
        .reset      ( reset_sw   ),
        // Controls
        .afilter_sw ( afilter_sw ),
        .vol_att    ( vol_att    ),
        .mix        ( AUDIO_MIX  ),
        .pause_core ( pause_core ),
        // Audio From Core
        .is_signed  ( AUDIO_S    ),
        .core_l     ( core_snd_l ),
        .core_r     ( core_snd_r ),
        // I2S
        .audio_mclk ( audio_mclk ),
        .audio_lrck ( audio_lrck ),
        .audio_dac  ( audio_dac  )
    );

    //! ------------------------------------------------------------------------
    //! Video
    //! ------------------------------------------------------------------------
    wire       [2:0] video_preset;     // Video Preset Configuration
    wire [BPP_R-1:0] core_r;           // Video Red
    wire [BPP_G-1:0] core_g;           // Video Green
    wire [BPP_B-1:0] core_b;           // Video Blue
    wire             core_hs, core_hb; // Horizontal Sync/Blank
    wire             core_vs, core_vb; // Vertical Sync/Blank
    wire             core_de;          // Display Enable

    assign core_hb = 1'b0;
    assign core_vb = 1'b0;

    video_mixer #(.RW(BPP_R),.GW(BPP_G),.BW(BPP_B)) pocket_video_mixer
    (
        // Clocks
        .clk_74a                  ( clk_74a                  ),
        .clk_sys                  ( clk_sys                  ),
        .clk_vid                  ( clk_vid                  ),
        .clk_vid_90deg            ( clk_vid_90deg            ),
        // Input Controls
        .video_preset             ( video_preset             ),
        .scnl_sw                  ( scnl_sw                  ),
        .smask_sw                 ( smask_sw                 ),
        // Input Video from Core
        .core_r                   ( core_r                   ),
        .core_g                   ( core_g                   ),
        .core_b                   ( core_b                   ),
        .core_vs                  ( core_vs                  ),
        .core_hs                  ( core_hs                  ),
        .core_de                  ( core_de                  ),
        // Output to Display
        .video_rgb                ( video_rgb                ),
        .video_vs                 ( video_vs                 ),
        .video_hs                 ( video_hs                 ),
        .video_de                 ( video_de                 ),
        .video_rgb_clock          ( video_rgb_clock          ),
        .video_rgb_clock_90       ( video_rgb_clock_90       ),
        // Pocket Bridge Slots
        .dataslot_requestwrite    ( dataslot_requestwrite    ), // [i]
        .dataslot_requestwrite_id ( dataslot_requestwrite_id ), // [i]
        .dataslot_allcomplete     ( dataslot_allcomplete     ), // [i]
        // MPU -> FPGA (MPU Write to FPGA)
        // Pocket Bridge
        .bridge_endian_little     ( bridge_endian_little     ), // [i]
        .bridge_addr              ( bridge_addr              ), // [i]
        .bridge_wr                ( bridge_wr                ), // [i]
        .bridge_wr_data           ( bridge_wr_data           )  // [i]
    );

    //! ------------------------------------------------------------------------
    //! Data I/O
    //! ------------------------------------------------------------------------
    wire              ioctl_download;
    wire       [15:0] ioctl_index;
    wire              ioctl_wr;
    wire [DIO_AW-1:0] ioctl_addr;
    wire [DIO_DW-1:0] ioctl_data;

    data_io #(.MASK(DIO_MASK),.AW(DIO_AW),.DW(DIO_DW),.DELAY(DIO_DELAY),.HOLD(DIO_HOLD)) pocket_data_io
    (
        // Clocks and Reset
        .clk_74a                  ( clk_74a                  ),
        .clk_memory               ( clk_sys                  ),
        // Pocket Bridge Slots
        .dataslot_requestwrite    ( dataslot_requestwrite    ), // [i]
        .dataslot_requestwrite_id ( dataslot_requestwrite_id ), // [i]
        .dataslot_allcomplete     ( dataslot_allcomplete     ), // [i]
        // MPU -> FPGA (MPU Write to FPGA)
        // Pocket Bridge
        .bridge_endian_little     ( bridge_endian_little     ), // [i]
        .bridge_addr              ( bridge_addr              ), // [i]
        .bridge_wr                ( bridge_wr                ), // [i]
        .bridge_wr_data           ( bridge_wr_data           ), // [i]
        // Controller Interface
        .ioctl_download           ( ioctl_download           ), // [o]
        .ioctl_index              ( ioctl_index              ), // [o]
        .ioctl_wr                 ( ioctl_wr                 ), // [o]
        .ioctl_addr               ( ioctl_addr               ), // [o]
        .ioctl_data               ( ioctl_data               )  // [o]
    );

    //! ------------------------------------------------------------------------
    //! Gamepad/Analog Stick
    //! ------------------------------------------------------------------------
    // Player 1
    // - DPAD
    wire       p1_up,     p1_down,   p1_left,   p1_right;
    wire       p1_btn_y,  p1_btn_x,  p1_btn_b,  p1_btn_a;
    wire       p1_btn_l1, p1_btn_l2, p1_btn_l3;
    wire       p1_btn_r1, p1_btn_r2, p1_btn_r3;
    wire       p1_select, p1_start;
    // - Analog
    wire       j1_up,     j1_down,   j1_left,   j1_right;
    wire [7:0] j1_lx,     j1_ly,     j1_rx,     j1_ry;
    // Player 2
    // - DPAD
    wire       p2_up,     p2_down,   p2_left,   p2_right;
    wire       p2_btn_y,  p2_btn_x,  p2_btn_b,  p2_btn_a;
    wire       p2_btn_l1, p2_btn_l2, p2_btn_l3;
    wire       p2_btn_r1, p2_btn_r2, p2_btn_r3;
    wire       p2_select, p2_start;
    // - Analog
    wire       j2_up,     j2_down,   j2_left,   j2_right;
    wire [7:0] j2_lx,     j2_ly,     j2_rx,     j2_ry;
    // Single Player or Alternate 2 Players for Arcade (unused: both players are wired)
    wire m_start1, m_start2;
    wire m_coin1,  m_coin2, m_coin;
    wire m_up,     m_down,  m_left, m_right;
    wire m_btn1,   m_btn2,  m_btn3, m_btn4;
    wire m_btn5,   m_btn6,  m_btn7, m_btn8;

    gamepad #(.JOY_PADS(JOY_PADS),.JOY_ALT(JOY_ALT)) pocket_gamepad
    (
        .clk_sys   ( clk_sys   ),
        // Pocket PAD Interface
        .cont1_key ( cont1_key ), .cont1_joy ( cont1_joy ),
        .cont2_key ( cont2_key ), .cont2_joy ( cont2_joy ),
        .cont3_key ( cont3_key ), .cont3_joy ( cont3_joy ),
        .cont4_key ( cont4_key ), .cont4_joy ( cont4_joy ),
        // Player 1
        .p1_up     ( p1_up     ), .p1_down   ( p1_down   ),
        .p1_left   ( p1_left   ), .p1_right  ( p1_right  ),
        .p1_y      ( p1_btn_y  ), .p1_x      ( p1_btn_x  ),
        .p1_b      ( p1_btn_b  ), .p1_a      ( p1_btn_a  ),
        .p1_l1     ( p1_btn_l1 ), .p1_r1     ( p1_btn_r1 ),
        .p1_l2     ( p1_btn_l2 ), .p1_r2     ( p1_btn_r2 ),
        .p1_l3     ( p1_btn_l3 ), .p1_r3     ( p1_btn_r3 ),
        .p1_se     ( p1_select ), .p1_st     ( p1_start  ),
        .j1_up     ( j1_up     ), .j1_down   ( j1_down   ),
        .j1_left   ( j1_left   ), .j1_right  ( j1_right  ),
        .j1_lx     ( j1_lx     ), .j1_ly     ( j1_ly     ),
        .j1_rx     ( j1_rx     ), .j1_ry     ( j1_ry     ),
        // Player 2
        .p2_up     ( p2_up     ), .p2_down   ( p2_down   ),
        .p2_left   ( p2_left   ), .p2_right  ( p2_right  ),
        .p2_y      ( p2_btn_y  ), .p2_x      ( p2_btn_x  ),
        .p2_b      ( p2_btn_b  ), .p2_a      ( p2_btn_a  ),
        .p2_l1     ( p2_btn_l1 ), .p2_r1     ( p2_btn_r1 ),
        .p2_l2     ( p2_btn_l2 ), .p2_r2     ( p2_btn_r2 ),
        .p2_l3     ( p2_btn_l3 ), .p2_r3     ( p2_btn_r3 ),
        .p2_se     ( p2_select ), .p2_st     ( p2_start  ),
        .j2_up     ( j2_up     ), .j2_down   ( j2_down   ),
        .j2_left   ( j2_left   ), .j2_right  ( j2_right  ),
        .j2_lx     ( j2_lx     ), .j2_ly     ( j2_ly     ),
        .j2_rx     ( j2_rx     ), .j2_ry     ( j2_ry     ),
        // Single Player or Alternate 2 Players for Arcade
        .m_coin    ( m_coin    ),                           // Coinage P1 or P2
        .m_up      ( m_up      ), .m_down    ( m_down    ), // Up/Down
        .m_left    ( m_left    ), .m_right   ( m_right   ), // Left/Right
        .m_btn1    ( m_btn1    ), .m_btn4    ( m_btn4    ), // Y/X
        .m_btn2    ( m_btn2    ), .m_btn3    ( m_btn3    ), // B/A
        .m_btn5    ( m_btn5    ), .m_btn6    ( m_btn6    ), // L1/R1
        .m_btn7    ( m_btn7    ), .m_btn8    ( m_btn8    ), // L2/R2
        .m_coin1   ( m_coin1   ), .m_coin2   ( m_coin2   ), // P1/P2 Coin
        .m_start1  ( m_start1  ), .m_start2  ( m_start2  )  // P1/P2 Start
    );

    //! ------------------------------------------------------------------------
    //! Clocks
    //! ------------------------------------------------------------------------
    wire pll_core_locked, pll_core_locked_s;
    wire clk_sys;       // Machine, renderers and memories: 96.0 MHz
    wire clk_vid;       // Video: 8.0 MHz dot clock, exactly clk_sys / 12, half a system cycle late
    wire clk_vid_90deg; // Video: 8.0 MHz @ 90deg (Pocket RGB clock pair)
    wire clk_sdram;     // SDRAM chip clock: 96.0 MHz, phase-shifted (see the SDC)
    wire clk_unused1;

    core_pll core_pll
    (
        .refclk   ( clk_74a ),
        .rst      ( 0       ),
        .outclk_0 ( clk_sys       ),
        .outclk_1 ( clk_vid       ),
        .outclk_2 ( clk_vid_90deg ),
        .outclk_3 ( clk_sdram     ),
        .outclk_4 ( clk_unused1   ),
        .locked   ( pll_core_locked )
    );

    // Synchronize pll_core_locked into clk_74a domain before usage
    synch_3 sync_lck(pll_core_locked, pll_core_locked_s, clk_74a);

    //! ------------------------------------------------------------------------
    //! @ The game
    //! ------------------------------------------------------------------------
    wire reset_sw_s;
    synch_3 sync_rst(reset_sw, reset_sw_s, clk_sys);
    wire pll_locked_sys;
    synch_3 sync_lck2(pll_core_locked, pll_locked_sys, clk_sys);

    //! The SDRAM initialises on the hardware reset; the machine is held until
    //! the SDRAM is ready and the host's first "all complete" has been seen
    //! (sticky, because the bridge clears all-complete on any later slot
    //! request), and by the menu's reset switch.
    wire mem_init  = ~pll_locked_sys;
    wire mem_ready;
    logic loaded = 1'b0;
    wire  allc_s;
    synch_3 sync_allc(dataslot_allcomplete, allc_s, clk_sys);
    always_ff @(posedge clk_sys) if (allc_s) loaded <= 1'b1;
    wire  g_reset = reset_sw_s | ~loaded | ~mem_ready | ~sram_done;

    //! ROM: one slot with the flat image tools/mra_build.py makes from nbajam.mra.
    //! Its layout is in target/pocket/nbajam_mem.sv; change the two together.
    wire        ioctl_isROM = ioctl_download && ioctl_index == 16'h1;   // slot 0 is the instance JSON (Pleiads' layout)
    wire        dl_we       = ioctl_isROM && ioctl_wr;
    wire [24:0] dl_addr     = ioctl_addr[24:0];
    wire  [7:0] dl_data     = ioctl_data;

    //! Controls, active low as the board reads them (docs/hardware.md 3):
    //!   IN0  P1 bits 0-3 up/down/left/right, 4 shoot/block, 5 pass/steal,
    //!        6 turbo; P2 the same in bits 8-14
    //!   IN1  0 coin 1, 1 coin 2, 2 start 1, 3 tilt, 4 service (test),
    //!        5 start 2, 6 service credit, 7-8 coins 3-4, 9-10 starts 3-4
    //!   IN2  players 3 and 4 (not wired: two Pocket controllers)
    //! On the Pocket, laid out like the arcade panel's Turbo / Shoot / Pass
    //! from left to right: Y turbo, X shoot, A pass; B is a second pass and R
    //! a second turbo; select is a coin.
    wire p1_sh = p1_btn_x, p1_pa = p1_btn_a | p1_btn_b, p1_tu = p1_btn_y | p1_btn_r1;
    wire p2_sh = p2_btn_x, p2_pa = p2_btn_a | p2_btn_b, p2_tu = p2_btn_y | p2_btn_r1;
    wire svc   = mod_sw1[0] | svc_sw;

    wire [15:0] g_in0 = ~{1'b0, p2_tu, p2_pa, p2_sh,
                          p2_right | j2_right, p2_left | j2_left, p2_down | j2_down, p2_up | j2_up,
                          1'b0, p1_tu, p1_pa, p1_sh,
                          p1_right | j1_right, p1_left | j1_left, p1_down | j1_down, p1_up | j1_up};
    wire [15:0] g_in1 = ~{10'd0, p2_start, svc, 1'b0, p1_start, p2_select, p1_select};
    wire [15:0] g_in2 = 16'hffff;

    //! The DIP word.  The menu word starts at zero and is XORed with the
    //! factory setting MAME ships, 0x7FFD (docs/hardware.md 3), so nothing set
    //! is the board as it left Midway and each menu value is the difference.
    //! Every entry in interact.json must do something on hardware (5.5).
    wire [15:0] g_dsw = 16'h7ffd ^ {dip_sw1, dip_sw0};

    //! Bring-up switches from the modifier word (the "Bring-up" entries of
    //! interact.json; take them off the menu for a release, leave them here):
    //! bit 4 SDRAM read capture alternate, 5 slow bursts, 7 slow SRAM reads,
    //! and mod_sw1 bit 7 stretched SRAM writes.
    wire g_rd_late      = ~mod_sw0[4];
    wire g_burst_slow   =  mod_sw0[5];
    // SDRAM bursts, a menu list: Fast (one word a clock), Normal (one every 2,
    // the spacing the earlier cores run on hardware), Slow (one every 5).  The
    // first flash showed wrong colours with Fast and a perfect picture with
    // Slow; Normal was not on that build.  Normal is all bits clear, so it is
    // what runs whether or not the firmware writes the menu's default.
    wire g_burst_fast   =  mod_sw0[6] & ~mod_sw0[5];     // reads
    // Writes one a clock by default: on hardware the blitter and the page
    // clear need it (Normal dropped TE's busiest scenes to half rate) and the
    // write pace is sound on the Pocket; reads stay one every 2 (one a clock
    // garbled the palette byte).  All bits clear = this, as tested.
    wire g_burst_fast_wr = ~mod_sw1[1] & ~mod_sw0[5];    // writes
    wire g_sram_slow    =  mod_sw0[7];
    wire g_sram_slow_wr =  mod_sw1[7];

    // the core's memory ports (rtl/nbajam_core.sv)
    wire        sd_req, sd_we, sd_ack;   wire [24:1] sd_addr;  wire [15:0] sd_wdata, sd_q;  wire [1:0] sd_be;
    wire [24:1] b_addr;  wire [9:0] b_len, b_idx, b_widx, b_wpre;
    wire        b_req, b_we, b_wr, b_done;  wire [15:0] b_wdata, b_data;  wire [1:0] b_be;
    wire        oki_req, oki_ack;  wire [19:0] oki_addr;  wire [7:0] oki_q;
    wire        srom_req, srom_ack;  wire [16:0] srom_addr;  wire [7:0] srom_q;

    //! ------------------------------------------------------------------
    //! SRAM bring-up test (target/pocket/sram_selftest.sv): after the download
    //! has written the sound CPU's program and before the core is let out of
    //! reset, A55A and 5AA5 go into two words and come back out, and the
    //! panel shows what came back.  The two words are put back afterwards:
    //! the program uses all 64K words.  They sit either side of A15, the top
    //! address line this 16-bit port drives.
    //! ------------------------------------------------------------------
    wire [15:0] sram_rd0, sram_rd1;
    wire        sram_done, tv_req, tv_we;
    wire [16:0] tv_addr;
    wire [15:0] tv_din;
    wire        tv_ack;  wire [15:0] tv_q;
    sram_selftest #(.A0(17'h00000), .A1(17'h08000)) u_sramtest (
        .clk(clk_sys), .hold(!mem_ready || !loaded),
        .req(tv_req), .we(tv_we), .addr(tv_addr), .d(tv_din), .ack(tv_ack), .q(tv_q),
        .done(sram_done), .rd0(sram_rd0), .rd1(sram_rd1)
    );

    wire g_te;      // Tournament Edition, recognised by nbajam_mem as the image loads
    nbajam_mem u_mem (
        .clk(clk_sys), .clk_sdram(clk_sdram), .init(mem_init), .ready(mem_ready),
        .rd_late(g_rd_late), .burst_slow(g_burst_slow), .burst_fast(g_burst_fast), .burst_fast_wr(g_burst_fast_wr), .game_te(g_te),
        .sram_slow(g_sram_slow), .sram_slow_wr(g_sram_slow_wr),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_active(ioctl_isROM),
        .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_wdata(sd_wdata), .sd_be(sd_be),
        .sd_ack(sd_ack), .sd_q(sd_q),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_we(b_we), .b_wdata(b_wdata), .b_be(b_be),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done), .b_widx(b_widx), .b_wpre(b_wpre),
        .oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack), .oki_q(oki_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .tst_active(!sram_done), .tst_req(tv_req), .tst_we(tv_we), .tst_addr(tv_addr),
        .tst_din(tv_din), .tst_ack(tv_ack), .tst_q(tv_q),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_BA(dram_ba),
        .SDRAM_DQML(dram_dqm[0]), .SDRAM_DQMH(dram_dqm[1]),
        .SDRAM_CLK(dram_clk), .SDRAM_CKE(dram_cke),
        .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n), .SDRAM_nWE(dram_we_n),
        .SDRAM_nCS(),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    wire        g_pix_ce, g_hs, g_vs, g_de, g_vb, g_hb;
    wire [23:0] g_rgb;
    wire signed [15:0] g_snd;
    wire [31:0] g_pc;
    wire        g_unimpl, g_blit_busy;
    wire [15:0] g_late, g_skipmode, g_snd_stalls, g_snd_pc;

    //! The dot enable's phase is pinned to clk_vid: the clock's own toggle,
    //! seen through two system-clock flops, restarts the core's dot divider
    //! (clk_enables.sv), so the colour stage settles a fixed number of system
    //! clocks before the clk_vid edge that samples it.
    reg  vt = 1'b0;
    reg  vt_s, vt_d;
    always @(posedge clk_vid) vt <= ~vt;
    always @(posedge clk_sys) begin vt_s <= vt; vt_d <= vt_s; end
    wire pix_sync = vt_s ^ vt_d;

    nbajam_core u_core (
        //! pause_core is the Pocket's menu being open: it freezes the CPUs and
        //! the sound, never resets them (METHODOLOGY 5.5)
        .clk(clk_sys), .rst(g_reset), .pause(pause_core), .pix_sync(pix_sync), .te(g_te),
        .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_wdata(sd_wdata), .sd_be(sd_be),
        .sd_ack(sd_ack), .sd_q(sd_q),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_we(b_we), .b_wdata(b_wdata), .b_be(b_be),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done), .b_widx(b_widx), .b_wpre(b_wpre),
        .oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack), .oki_q(oki_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .in0(g_in0), .in1(g_in1), .in2(g_in2), .dsw(g_dsw),
        .nv_addr(po_nv_addr), .nv_we(po_nv_we), .nv_wdata(po_nv_wdata), .nv_rdata(po_nv_rdata),
        .nv_dirty(po_nv_dirty),
        .rgb(g_rgb), .hsync(g_hs), .vsync(g_vs),
        .hblank(g_hb), .vblank(g_vb), .pix_ce(g_pix_ce), .de(g_de),
        .snd(g_snd),
        .dbg_pc(g_pc), .dbg_unimpl(g_unimpl), .dbg_late(g_late), .dbg_skipmode(g_skipmode),
        .dbg_snd_stalls(g_snd_stalls), .dbg_snd_pc(g_snd_pc), .dbg_blit_busy(g_blit_busy)
    );

    //! Screen shape from the Interact menu.  The aspect in video.json
    //! describes the raster BEFORE the scaler rotates it (METHODOLOGY 5.5).
    wire [1:0] aspect_sel = mod_sw0[2:1];
    assign video_preset = (aspect_sel == 2'd1) ? 3'd1 : 3'd0;

    //! ------------------------------------------------------------------
    //! The bring-up panel (rtl/dbg_overlay.sv, METHODOLOGY 5.21), on the
    //! modifier word's bit 3.  Four rows of 32 squares on the bottom sixteen
    //! lines, green = 1, bit 31 of each row leftmost.  The raster runs while
    //! the machine is held in reset, so a black Pocket can still be read.
    //! KEEP docs/bringup.md IN STEP WITH THIS.
    //!   row 0  1010 1010 | frame count | pll locked, memory ready,
    //!          downloading, all-complete, loaded, core reset, SRAM test
    //!          done, blitter busy | IN1 low byte
    //!   row 1  the TMS34010's PC: live, or -- once the CPU has met an
    //!          instruction it does not implement -- frozen there, with
    //!          bit 31 set (the first fault, not the current state)
    //!   row 2  scan-out lines fetched late | scaled skip-mode blits |
    //!          sound-ROM stalls | sound PC high byte (each saturating)
    //!   row 3  the SRAM self-test: A55A 5AA5 is a pass
    //! ------------------------------------------------------------------
    wire        ovl_en = mod_sw0[3];
    logic [7:0] ovl_frames;
    logic       vb_d;
    always_ff @(posedge clk_sys) begin
        vb_d <= g_vb;
        if (g_vb && !vb_d) ovl_frames <= ovl_frames + 8'd1;
    end

    //! First fault: the PC when the CPU first raised `unimpl`, latched.
    //! Proven quiet on a healthy boot in sim/run_machine.sh (unimpl 0).
    logic [31:0] flt_pc;
    logic        flt_seen;
    always_ff @(posedge clk_sys) begin
        if (g_reset) flt_seen <= 1'b0;
        else if (g_unimpl && !flt_seen) begin flt_seen <= 1'b1; flt_pc <= g_pc; end
    end
    wire [31:0] pc_row = flt_seen ? {1'b1, flt_pc[30:0]} : {1'b0, g_pc[30:0]};
    function automatic logic [7:0] sat8(input logic [15:0] v);
        return (v > 16'd255) ? 8'hff : v[7:0];
    endfunction

    wire [127:0] ovl_status = {
        8'b1010_1010, ovl_frames,
        pll_locked_sys, mem_ready, ioctl_download, allc_s,
        loaded, g_reset, sram_done, g_blit_busy,
        g_in1[7:0],
        pc_row,
        sat8(g_late), sat8(g_skipmode), sat8(g_snd_stalls), g_snd_pc[15:8],
        sram_rd0, sram_rd1
    };

    wire [7:0] ovl_r, ovl_g, ovl_b;
    dbg_overlay ovl (
        .clk(clk_sys), .cen_pix(g_pix_ce), .enable(ovl_en), .de(g_de), .vsync(g_vs),
        .r_in(g_rgb[23:16]), .g_in(g_rgb[15:8]), .b_in(g_rgb[7:0]),
        .status(ovl_status), .r_out(ovl_r), .g_out(ovl_g), .b_out(ovl_b)
    );

    //! ------------------------------------------------------------------
    //! Video.  The core emits one pixel per 8 MHz enable in the 96 MHz
    //! domain and holds it for the twelve cycles; clk_vid is the same
    //! 8 MHz from the same PLL, half a system cycle after a system edge,
    //! so the sample is taken well inside the held value.
    //! ------------------------------------------------------------------
    reg [7:0] vr_q, vg_q, vb_q;
    reg       vhs_q, vvs_q, vde_q;
    always @(posedge clk_vid) begin
        vr_q  <= ovl_r; vg_q <= ovl_g; vb_q <= ovl_b;
        vhs_q <= g_hs; vvs_q <= g_vs; vde_q <= g_de;
    end
    assign core_r  = vr_q;
    assign core_g  = vg_q;
    assign core_b  = vb_q;
    assign core_hs = vhs_q;
    assign core_vs = vvs_q;
    assign core_de = vde_q;

    //! ------------------------------------------------------------------
    //! Audio clock domain crossing (METHODOLOGY section 5.4).  The mixer's
    //! output moves on every 96 MHz clock, so it must never be sampled
    //! directly by the audio side: it is sampled here at 48 kHz, held, and
    //! handed over with a toggle flag, which is the only way the audio
    //! domain can be sure of a whole sample rather than a mix of two.
    //! ------------------------------------------------------------------
    localparam int SND_DIV = 2000;              // 96 MHz / 48 kHz
    logic [11:0] snd_div = 12'd0;
    logic signed [15:0] snd_hold = 16'sd0;
    logic        snd_tog = 1'b0;
    always_ff @(posedge clk_sys) begin
        if (snd_div == 12'(SND_DIV - 1)) begin
            snd_div  <= 12'd0;
            snd_hold <= g_snd;
            snd_tog  <= ~snd_tog;
        end else begin
            snd_div <= snd_div + 12'd1;
        end
    end
    logic [2:0] snd_tog_s = 3'd0;
    logic signed [15:0] snd_xfer = 16'sd0;
    always_ff @(posedge clk_74b) begin
        snd_tog_s <= {snd_tog_s[1:0], snd_tog};
        if (snd_tog_s[2] != snd_tog_s[1]) snd_xfer <= snd_hold;
    end
    assign core_snd_l = snd_xfer;
    assign core_snd_r = snd_xfer;

endmodule
