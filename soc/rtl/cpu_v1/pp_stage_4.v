`timescale 1ns / 1ps

// EX/MEM pipeline register
// The memory request itself is issued from EX (sync SRAM), so MEM only
// receives the read data. result = ALU result, or PC+4 for JAL/JALR.
module pp_stage_4(
input clk,
input reset,
input freeze,

input RegWrite_s3,
input [1:0] ResultSrc_s3,
input [31:0] result,
input [2:0] funct3_s3,
input [4:0] RdE,
output reg RegWrite_s4,
output reg [1:0] ResultSrc_s4,
output reg [31:0] result_s4,
output reg [2:0] funct3_s4,
output reg [4:0] RdM
    );
    always @(posedge clk) begin
    if(reset) begin
    RegWrite_s4 <= 0;
    ResultSrc_s4 <= 0;
    result_s4 <=0;
    funct3_s4 <= 0;
    RdM <= 0;
    end
    else if(!freeze) begin
    RegWrite_s4 <= RegWrite_s3;
    ResultSrc_s4 <= ResultSrc_s3;
    result_s4 <=result;
    funct3_s4 <= funct3_s3;
    RdM <= RdE;
    end
    end
endmodule
