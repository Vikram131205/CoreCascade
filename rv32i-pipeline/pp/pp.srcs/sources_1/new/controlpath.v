`timescale 1ns / 1ps
// Main decoder (ID stage)
// ALUSrcA : 00 = rs1, 01 = PC, 10 = zero
// ResultSrc: 00 = ALU (or CSR old value / MDU result), 01 = load data, 10 = PC+4
// Exceptions flagged here are taken when the instruction reaches EX.
module controlpath(
input flush,
input [11:0] imm,
input reset,
input [6:0] ins,
input [2:0] funct3,
input [6:0] funct7,
output reg RegWrite,MemWrite,MemRead,Jump,JumpReg,Branch,ALUSrc,
output reg Csr,Mret,
output reg Mul,                    // M extension op (MDU)
output reg Illegal,Ecall,Ebreak,   // synchronous exceptions
output reg [1:0] ALUSrcA,
output reg [1:0] ResultSrc,
output reg [2:0] imsrc,
output reg [3:0] alucontrol
    );
    always @(*) begin
    // defaults = NOP
    RegWrite = 0;
    MemWrite = 0;
    MemRead = 0;
    Jump = 0;
    JumpReg = 0;
    Branch = 0;
    ALUSrc = 0;
    Csr = 0;
    Mret = 0;
    Mul = 0;
    Illegal = 0;
    Ecall = 0;
    Ebreak = 0;
    ALUSrcA = 2'b00;
    ResultSrc = 2'b00;
    imsrc = 3'b000;
    alucontrol = 4'd0;

    if(!(reset | flush)) begin
    case(ins)
    7'b0110011 : begin // R type (base and M extension)
    if(funct7 == 7'b0000001) begin
    Mul = 1;
    RegWrite = 1;
    end
    else if(funct7 == 7'd0 || (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101))) begin
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
    else Illegal = 1;
    end

    7'b0010011 : begin  // I type
    if((funct3 == 3'b001 && imm[11:5] != 7'd0) ||
       (funct3 == 3'b101 && imm[11:5] != 7'd0 && imm[11:5] != 7'b0100000))
    Illegal = 1;
    else begin
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
    end

    7'b0000011 : begin // load - width/sign handled by funct3 in MEM
    if(funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111) Illegal = 1;
    else begin
    RegWrite = 1;
    MemRead = 1;
    ALUSrc = 1;
    ResultSrc = 2'b01;
    imsrc = 3'b000;
    end
    end

    7'b0100011 : begin // store - width handled by funct3 in EX
    if(funct3[2] || funct3 == 3'b011) Illegal = 1;
    else begin
    MemWrite = 1;
    ALUSrc = 1;
    imsrc = 3'b010;
    end
    end

    7'b1100011 : begin // branch
    if(funct3 == 3'b010 || funct3 == 3'b011) Illegal = 1;
    else begin
    Branch = 1;
    imsrc = 3'b011;
    end
    end

    7'b1101111 : begin // JAL
    Jump = 1;
    RegWrite = 1;
    ALUSrc = 1;
    ResultSrc = 2'b10;
    imsrc = 3'b100;
    end

    7'b1100111 : begin // JALR : target = (rs1 + imm) & ~1
    if(funct3 != 3'b000) Illegal = 1;
    else begin
    Jump = 1;
    JumpReg = 1;
    RegWrite = 1;
    ALUSrc = 1;
    ResultSrc = 2'b10;
    imsrc = 3'b000;
    end
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

    7'b0001111 : ; // FENCE / FENCE.I : in-order single-issue core, nothing to do

    7'b1110011 : begin // SYSTEM
    if(funct3 == 3'b000) begin
    case(imm)
    12'h000 : Ecall = 1;
    12'h001 : Ebreak = 1;
    12'h302 : Mret = 1;
    12'h105 : ;            // WFI : allowed to act as NOP
    default : Illegal = 1;
    endcase
    end
    else if(funct3 == 3'b100) Illegal = 1;
    else begin // CSRRW/S/C and immediate forms; CSR address = zero-extended imm
    Csr = 1;
    RegWrite = 1;
    imsrc = 3'b001;
    end
    end

    default : Illegal = 1;
   endcase
   end
   end
endmodule
