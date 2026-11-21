`timescale 1ns / 1ps
// Main decoder (ID stage)
// ALUSrcA : 00 = rs1, 01 = PC, 10 = zero
// ResultSrc: 00 = ALU (or CSR old value when Csr), 01 = load data, 10 = PC+4
module controlpath(
input flush,
input [11:0] imm,
input reset,
input [6:0] ins,
input [2:0] funct3,
input [6:0] funct7,
output reg RegWrite,MemWrite,MemRead,Jump,JumpReg,Branch,ALUSrc,
output reg Csr,Mret,
output reg [1:0] ALUSrcA,
output reg [1:0] ResultSrc,
output reg [2:0] imsrc,
output reg [3:0] alucontrol
    );
    always @(*) begin
    // defaults = NOP (also used for FENCE / ECALL / EBREAK / illegal)
    RegWrite = 0;
    MemWrite = 0;
    MemRead = 0;
    Jump = 0;
    JumpReg = 0;
    Branch = 0;
    ALUSrc = 0;
    Csr = 0;
    Mret = 0;
    ALUSrcA = 2'b00;
    ResultSrc = 2'b00;
    imsrc = 3'b000;
    alucontrol = 4'd0;

    if(!(reset | flush)) begin
    case(ins)
    7'b0110011 : begin // R type
    RegWrite = 1;
    case(funct3)
    3'b000 : alucontrol = (funct7 == 7'd0) ? 4'd0 : 4'd1;  // ADD / SUB
    3'b100 : alucontrol = 4'd5;
    3'b110 : alucontrol = 4'd3;
    3'b111 : alucontrol = 4'd4;
    3'b001 : alucontrol = 4'd2;
    3'b101 : alucontrol = (funct7 == 7'd0) ? 4'd7 : 4'd8;  // SRL / SRA
    3'b010 : alucontrol = 4'd9;
    3'b011 : alucontrol = 4'd6;
    endcase
    end

    7'b0010011 : begin  // I type
    RegWrite = 1;
    ALUSrc = 1;
    imsrc = 3'b101;
    case(funct3)
    3'b000 : alucontrol = 4'd0;
    3'b100 : alucontrol = 4'd5;
    3'b110 : alucontrol = 4'd3;
    3'b111 : alucontrol = 4'd4;
    3'b001 : alucontrol = 4'd2;
    3'b101 : alucontrol = (imm[11:5] == 7'd0) ? 4'd7 : 4'd8;  // SRLI / SRAI
    3'b010 : alucontrol = 4'd9;
    3'b011 : alucontrol = 4'd6;
    endcase
    end

    7'b0000011 : begin // load (I type) - width/sign handled by funct3 in MEM
    RegWrite = 1;
    MemRead = 1;
    ALUSrc = 1;
    ResultSrc = 2'b01;
    imsrc = 3'b000;
    end

    7'b0100011 : begin // store (S type) - width handled by funct3 in EX
    MemWrite = 1;
    ALUSrc = 1;
    imsrc = 3'b010;
    end

    7'b1100011 : begin // (B Type)
    Branch = 1;
    imsrc = 3'b011;
    end

    7'b1101111 : begin // JAL
    Jump = 1;
    RegWrite = 1;
    ALUSrc = 1;
    ResultSrc = 2'b10;
    imsrc = 3'b100;
    end

    7'b1100111 : begin // JALR : target = (rs1 + imm) & ~1
    Jump = 1;
    JumpReg = 1;
    RegWrite = 1;
    ALUSrc = 1;
    ResultSrc = 2'b10;
    imsrc = 3'b000;
    end

    7'b0110111 : begin // LUI : rd = 0 + imm_u
    RegWrite = 1;
    ALUSrc = 1;
    ALUSrcA = 2'b10;
    imsrc = 3'b110;
    end

    7'b0010111 : begin // AUIPC : rd = PC + imm_u
    RegWrite = 1;
    ALUSrc = 1;
    ALUSrcA = 2'b01;
    imsrc = 3'b110;
    end

    7'b1110011 : begin // SYSTEM
    if(funct3 == 3'b000) begin
    // MRET; ECALL / EBREAK / WFI execute as NOP
    if(imm == 12'h302) Mret = 1;
    end
    else begin // CSRRW/S/C and immediate forms; CSR address = zero-extended imm
    Csr = 1;
    RegWrite = 1;
    imsrc = 3'b001;
    end
    end

    default : ;
   endcase
   end
   end
endmodule
