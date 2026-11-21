`timescale 1ns / 1ps
// ============================================================================
//  Dual-port synchronous SRAM, 32-bit words, byte write enables per port.
//  Used for the CPU's ITCM and DTCM (CPU on port A, crossbar on port B).
//  FPGA: true dual-port block RAM. ASIC: sky130 1rw1r macro (or DFFRAM).
//  Same-address write on both ports in one cycle is undefined (never happens:
//  port B writes only while the CPU is held in reset by the boot loader).
// ============================================================================
module sram_dp #(
    parameter WORDS     = 1024,
    parameter INIT_FILE = ""
) (
    input                          clk,
    input                          a_en,
    input                          a_we,
    input      [3:0]               a_be,
    input      [$clog2(WORDS)-1:0] a_addr,
    input      [31:0]              a_wdata,
    output reg [31:0]              a_rdata,
    input                          b_en,
    input                          b_we,
    input      [3:0]               b_be,
    input      [$clog2(WORDS)-1:0] b_addr,
    input      [31:0]              b_wdata,
    output reg [31:0]              b_rdata
);
    reg [31:0] mem [0:WORDS-1];

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        if (a_en) begin
            if (a_we) begin
                if (a_be[0]) mem[a_addr][7:0]   <= a_wdata[7:0];
                if (a_be[1]) mem[a_addr][15:8]  <= a_wdata[15:8];
                if (a_be[2]) mem[a_addr][23:16] <= a_wdata[23:16];
                if (a_be[3]) mem[a_addr][31:24] <= a_wdata[31:24];
            end
            a_rdata <= mem[a_addr];
        end
    end

    always @(posedge clk) begin
        if (b_en) begin
            if (b_we) begin
                if (b_be[0]) mem[b_addr][7:0]   <= b_wdata[7:0];
                if (b_be[1]) mem[b_addr][15:8]  <= b_wdata[15:8];
                if (b_be[2]) mem[b_addr][23:16] <= b_wdata[23:16];
                if (b_be[3]) mem[b_addr][31:24] <= b_wdata[31:24];
            end
            b_rdata <= mem[b_addr];
        end
    end
endmodule
