`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    08:11:34 09/23/2016 
// Design Name: 
// Module Name:    mc6809e 
// Project Name: 
// Target Devices: 
// Tool versions: 
// Description: 
//
// Dependencies: 
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////
module mc6809e(
    input   [7:0] D,
    output  [7:0] DOut,
    output  [15:0] ADDR,
    output  RnW,
    input   E,
    input   Q,
    input   clk,
    input   cen_e,
    input   cen_q,
    output  BS,
    output  BA,
    input   nIRQ,
    input   nFIRQ,
    input   nNMI,
    output  AVMA,
    output  BUSY,
    output  LIC,
    input 	nHALT,	 
    input   nRESET

    );



mc6809i cpucore (.D(D), .DOut(DOut), .ADDR(ADDR), .RnW(RnW), .E(E), .Q(Q), .clk(clk), .cen_e(cen_e), .cen_q(cen_q), .BS(BS), .BA(BA), .nIRQ(nIRQ), .nFIRQ(nFIRQ), 
                .nNMI(nNMI), .AVMA(AVMA), .BUSY(BUSY), .LIC(LIC), .nHALT(nHALT), .nRESET(nRESET), .nDMABREQ(1'b1)
                );


endmodule
