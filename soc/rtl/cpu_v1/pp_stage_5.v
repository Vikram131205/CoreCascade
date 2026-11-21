`timescale 1ns / 1ps

// MEM/WB pipeline register
module pp_stage_5(
input clk,
input reset,
input freeze,

input RegWrite_s4,
input [1:0] ResultSrc_s4,
input [31:0] result_s4,
input [31:0] read_data,
input [4:0] RdM,

output reg  RegWrite_s5,
output reg [1:0] ResultSrc_s5,
output reg [31:0] result_s5,
output reg [31:0] read_data_s5,
output reg [4:0] RdW

    );
    always @(posedge clk) begin
    if(reset) begin
    RegWrite_s5 <= 0;
    ResultSrc_s5 <= 0;
    result_s5 <=0;
    read_data_s5 <=0;
    RdW <= 0;
    end
    else if(!freeze) begin
    RegWrite_s5 <= RegWrite_s4;
    ResultSrc_s5 <= ResultSrc_s4;
    result_s5 <= result_s4;
    read_data_s5 <=read_data;
    RdW <= RdM;
    end
    end
endmodule
