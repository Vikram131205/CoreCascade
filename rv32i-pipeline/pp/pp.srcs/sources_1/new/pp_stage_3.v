`timescale 1ns / 1ps

// ID/EX pipeline register
module pp_stage_3(
input clk,
input reset,
input flush,
input stall,
input freeze,   // data bus not granted: hold (must NOT bubble the waiting load/store)

input  RegWrite,MemWrite,MemRead,Jump,JumpReg,Branch,ALUSrc,Csr,Mret,
input  Mul,Illegal,Ecall,Ebreak,valid_s2,
input [1:0] ALUSrcA,
input [1:0] ResultSrc,
input [3:0] alucontrol,
input [31:0] r_data_1,r_data_2,
input  [31:0] next_addr_s2,
input  [31:0] four_pc_s2,
input [31:0] offset,
input [2:0] funct3,
input [4:0] Rs1D , Rs2D, RdD,

output reg  RegWrite_s3,MemWrite_s3,MemRead_s3,Jump_s3,JumpReg_s3,Branch_s3,ALUSrc_s3,Csr_s3,Mret_s3,
output reg  Mul_s3,Illegal_s3,Ecall_s3,Ebreak_s3,valid_s3,
output reg [1:0] ALUSrcA_s3,
output reg [1:0] ResultSrc_s3,
output reg [3:0] alucontrol_s3,
output reg [31:0] r_data_1_s3,r_data_2_s3,
output reg  [31:0] next_addr_s3,
output reg  [31:0] four_pc_s3,
output reg [31:0] offset_s3,
output reg [2:0] funct3_s3,
output reg [4:0] Rs1E , Rs2E , RdE
    );
    always @(posedge clk) begin
    if(reset | (!freeze & (flush | stall))) begin
    RegWrite_s3 <= 0;
    MemWrite_s3 <= 0;
    MemRead_s3 <= 0;
    Jump_s3 <= 0;
    JumpReg_s3 <= 0;
    Branch_s3 <= 0;
    ALUSrc_s3 <= 0;
    Csr_s3 <= 0;
    Mret_s3 <= 0;
    Mul_s3 <= 0;
    Illegal_s3 <= 0;
    Ecall_s3 <= 0;
    Ebreak_s3 <= 0;
    valid_s3 <= 0;
    ALUSrcA_s3 <= 0;
    ResultSrc_s3 <=0;
    alucontrol_s3 <=0;
    r_data_1_s3 <= 0;
    r_data_2_s3 <= 0;
    next_addr_s3 <=0;
    four_pc_s3 <= 0;
    offset_s3 <=0;
    funct3_s3 <= 0;
    Rs1E <= 0;
    Rs2E <= 0;
    RdE <= 0;
    end
    else if(!freeze) begin
    RegWrite_s3 <= RegWrite;
    MemWrite_s3 <= MemWrite;
    MemRead_s3 <= MemRead;
    Jump_s3 <= Jump;
    JumpReg_s3 <= JumpReg;
    Branch_s3 <= Branch;
    ALUSrc_s3 <= ALUSrc;
    Csr_s3 <= Csr;
    Mret_s3 <= Mret;
    Mul_s3 <= Mul;
    Illegal_s3 <= Illegal;
    Ecall_s3 <= Ecall;
    Ebreak_s3 <= Ebreak;
    valid_s3 <= valid_s2;
    ALUSrcA_s3 <= ALUSrcA;
    ResultSrc_s3 <= ResultSrc;
    alucontrol_s3 <=alucontrol;
    r_data_1_s3 <= r_data_1;
    r_data_2_s3 <= r_data_2 ;
    next_addr_s3 <=next_addr_s2;
    four_pc_s3 <= four_pc_s2 ;
    offset_s3 <=offset;
    funct3_s3 <= funct3;
    Rs1E <= Rs1D;
    Rs2E <= Rs2D;
    RdE <= RdD;
    end
    end
endmodule
