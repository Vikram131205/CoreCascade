`timescale 1ns / 1ps
// ============================================================================
//  One shared-SRAM bank as an OBI slave: always grants, answers next cycle.
//  Banks are word-interleaved, so the row inside the bank starts at address
//  bit ROW_LSB (= 2 + log2(number of banks)).
// ============================================================================
module obi_sram #(
    parameter WORDS   = 8192,     // 32 KB per bank
    parameter ROW_LSB = 5         // 8 banks
) (
    input         clk,
    input         reset,
    input         req,
    input         we,
    input  [3:0]  be,
    input  [31:0] addr,
    input  [31:0] wdata,
    output        gnt,
    output reg    rvalid,
    output [31:0] rdata,
    output        err
);
    localparam AW = $clog2(WORDS);
    assign gnt = 1'b1;
    assign err = 1'b0;

    always @(posedge clk) rvalid <= !reset & req;

    sram_sp #(.WORDS(WORDS)) u_mem (
        .clk(clk), .en(req), .we(we), .be(be),
        .addr(addr[ROW_LSB +: AW]), .wdata(wdata), .rdata(rdata)
    );
endmodule
