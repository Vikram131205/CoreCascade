`timescale 1ns / 1ps

// EX/MEM pipeline register
// The memory request itself is issued from EX (sync SRAM), so MEM only
// receives the response. result = ALU result, PC+4, CSR or MDU value.
// kill turns the instruction leaving EX into a bubble (trap in EX or MEM).
module pp_stage_4(
input clk,
input reset,
input freeze,
input kill,

input RegWrite_s3,
input MemWrite_s3,
input [1:0] ResultSrc_s3,
input [31:0] result,
input [2:0] funct3_s3,
input [4:0] RdE,
input [31:0] pc_s3,
input valid_s3,
output reg RegWrite_s4,
output reg MemWrite_s4,
output reg [1:0] ResultSrc_s4,
output reg [31:0] result_s4,
output reg [2:0] funct3_s4,
output reg [4:0] RdM,
output reg [31:0] pc_s4,
output reg valid_s4
    );
    always @(posedge clk) begin
    if(reset | (kill & !freeze)) begin
    RegWrite_s4 <= 0;
    MemWrite_s4 <= 0;
    ResultSrc_s4 <= 0;
    result_s4 <=0;
    funct3_s4 <= 0;
    RdM <= 0;
    pc_s4 <= 0;
    valid_s4 <= 0;
    end
    else if(!freeze) begin
    RegWrite_s4 <= RegWrite_s3;
    MemWrite_s4 <= MemWrite_s3;
    ResultSrc_s4 <= ResultSrc_s3;
    result_s4 <=result;
    funct3_s4 <= funct3_s3;
    RdM <= RdE;
    pc_s4 <= pc_s3;
    valid_s4 <= valid_s3;
    end
    end
endmodule
