`timescale 1ns / 1ps
// ============================================================================
//  Single-port synchronous SRAM, 32-bit words, byte write enables.
//  Behavioural model: same timing as an SRAM macro (read data is registered,
//  valid the cycle after en=1). Infers BRAM on FPGA; replace with an
//  OpenRAM / DFFRAM / sky130 macro wrapper for ASIC.
// ============================================================================
module sram_sp #(
    parameter WORDS     = 256,
    parameter INIT_FILE = ""
) (
    input                          clk,
    input                          en,
    input                          we,
    input      [3:0]               be,
    input      [$clog2(WORDS)-1:0] addr,
    input      [31:0]              wdata,
    output reg [31:0]              rdata
);
    reg [31:0] mem [0:WORDS-1];

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        if (en) begin
            if (we) begin
                if (be[0]) mem[addr][7:0]   <= wdata[7:0];
                if (be[1]) mem[addr][15:8]  <= wdata[15:8];
                if (be[2]) mem[addr][23:16] <= wdata[23:16];
                if (be[3]) mem[addr][31:24] <= wdata[31:24];
            end
            rdata <= mem[addr];
        end
    end
endmodule
