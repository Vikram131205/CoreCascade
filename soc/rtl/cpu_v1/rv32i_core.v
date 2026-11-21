`timescale 1ns / 1ps
// ============================================================================
//  RV32I 5-stage pipelined core with external memory ports
// ============================================================================
//  Instruction port : synchronous-read memory, 1-cycle latency, always ready.
//                     imem_addr is presented one cycle before the PC register
//                     takes that value, so imem_rdata lines up with the PC.
//
//  Data port        : request is issued from EX, response arrives in MEM.
//                     dmem_req/we/be/addr/wdata are held until dmem_gnt=1.
//                     For reads, dmem_rdata is valid the cycle AFTER the grant.
//                     While dmem_req && !dmem_gnt the whole pipeline freezes.
//
//  Both ports match single-port synchronous SRAM macros (OpenRAM, DFFRAM,
//  sky130 sram), so the same core works on FPGA BRAM and ASIC SRAM.
//
//  Interrupts   : `irq` is a level-sensitive machine external interrupt.
//                 It is taken on the valid instruction in ID: EX/MEM/WB
//                 complete, ID/IF are flushed, mepc = PC of the ID instr,
//                 and fetch continues at mtvec. MRET (in EX) returns.
// ============================================================================
module rv32i_core (
    input             clk,
    input             reset,
    input             irq,           // machine external interrupt (level)

    // Instruction memory port
    output     [31:0] imem_addr,
    input      [31:0] imem_rdata,

    // Data memory / bus port
    output            dmem_req,
    output            dmem_we,
    output     [3:0]  dmem_be,
    output     [31:0] dmem_addr,
    output     [31:0] dmem_wdata,
    input             dmem_gnt,
    input      [31:0] dmem_rdata
);

// ---------------------------------------------------------------- signals
wire [31:0] pc, pc_next, four_pc, ins;
wire [31:0] next_addr_s2, ins_s2, four_pc_s2;
wire valid_s2;

wire RegWrite, MemWrite, MemRead, Jump, JumpReg, Branch, ALUSrc, Csr, Mret;
wire [1:0] ALUSrcA, ResultSrc;
wire [2:0] imsrc;
wire [3:0] alucontrol;
wire [31:0] r_data_1, r_data_2;
wire signed [31:0] offset;

wire RegWrite_s3, MemWrite_s3, MemRead_s3, Jump_s3, JumpReg_s3, Branch_s3, ALUSrc_s3, Csr_s3, Mret_s3;
wire [1:0] ALUSrcA_s3, ResultSrc_s3;
wire [3:0] alucontrol_s3;
wire [31:0] r_data_1_s3, r_data_2_s3, next_addr_s3, four_pc_s3, offset_s3;
wire [2:0] funct3_s3;
wire [4:0] Rs1E, Rs2E, RdE;

wire RegWrite_s4;
wire [1:0] ResultSrc_s4;
wire [31:0] result_s4;
wire [2:0] funct3_s4;
wire [4:0] RdM;

wire RegWrite_s5;
wire [1:0] ResultSrc_s5;
wire [31:0] result_s5, read_data_s5;
wire [4:0] RdW;

wire [31:0] write_data;
wire [1:0] ForwardAE, ForwardBE;
wire [31:0] true1, true2;
wire stall, flush, freeze;

wire [6:0] opcode = ins_s2[6:0];
wire [2:0] funct3 = ins_s2[14:12];
wire [6:0] funct7 = ins_s2[31:25];
wire [4:0] Rs1D   = ins_s2[19:15];
wire [4:0] Rs2D   = ins_s2[24:20];
wire [4:0] RdD    = ins_s2[11:7];

// ================================================================ IF
pc_ pc_reg (.clk(clk), .reset(reset), .stall(stall), .freeze(freeze),
            .addr(pc_next), .next_addr(pc));

alu_four pc_plus4 (.next_addr(pc), .four_pc(four_pc), .flush(flush));

// Sync-read SRAM: present the address the PC register will hold next cycle
assign imem_addr = reset            ? 32'd0 :
                   (stall | freeze) ? pc    : pc_next;
assign ins = imem_rdata;

pp_stage_2 pp2 (.clk(clk), .reset(reset), .flush(flush), .stall(stall), .freeze(freeze),
                .next_addr(pc), .ins(ins), .four_pc(four_pc),
                .next_addr_s2(next_addr_s2), .ins_s2(ins_s2), .four_pc_s2(four_pc_s2),
                .valid_s2(valid_s2));

// ================================================================ ID
controlpath ctrl (.reset(reset), .flush(flush), .ins(opcode), .imm(ins_s2[31:20]),
                  .funct3(funct3), .funct7(funct7),
                  .RegWrite(RegWrite), .MemWrite(MemWrite), .MemRead(MemRead),
                  .Jump(Jump), .JumpReg(JumpReg), .Branch(Branch),
                  .Csr(Csr), .Mret(Mret), .ALUSrc(ALUSrc), .ALUSrcA(ALUSrcA), .ResultSrc(ResultSrc),
                  .imsrc(imsrc), .alucontrol(alucontrol));

reg_file_ rf (.clk(clk), .flush(flush),
              .rs_addr(Rs1D), .rt_addr(Rs2D), .rd_addr(RdW),
              .write_data(write_data), .RegWrite(RegWrite_s5),
              .r_data_1(r_data_1), .r_data_2(r_data_2));

extender_offsethandler immgen (.funct3(funct3), .ins(ins_s2[31:7]), .imsrc(imsrc),
                               .offset(offset), .flush(flush));

pp_stage_3 pp3 (.clk(clk), .reset(reset), .flush(flush), .stall(stall), .freeze(freeze),
                .RegWrite(RegWrite), .MemWrite(MemWrite), .MemRead(MemRead),
                .Jump(Jump), .JumpReg(JumpReg), .Branch(Branch), .ALUSrc(ALUSrc),
                .Csr(Csr), .Mret(Mret), .ALUSrcA(ALUSrcA), .ResultSrc(ResultSrc), .alucontrol(alucontrol),
                .r_data_1(r_data_1), .r_data_2(r_data_2),
                .next_addr_s2(next_addr_s2), .four_pc_s2(four_pc_s2),
                .offset(offset), .funct3(funct3),
                .Rs1D(Rs1D), .Rs2D(Rs2D), .RdD(RdD),
                .RegWrite_s3(RegWrite_s3), .MemWrite_s3(MemWrite_s3), .MemRead_s3(MemRead_s3),
                .Jump_s3(Jump_s3), .JumpReg_s3(JumpReg_s3), .Branch_s3(Branch_s3),
                .ALUSrc_s3(ALUSrc_s3), .Csr_s3(Csr_s3), .Mret_s3(Mret_s3), .ALUSrcA_s3(ALUSrcA_s3), .ResultSrc_s3(ResultSrc_s3),
                .alucontrol_s3(alucontrol_s3),
                .r_data_1_s3(r_data_1_s3), .r_data_2_s3(r_data_2_s3),
                .next_addr_s3(next_addr_s3), .four_pc_s3(four_pc_s3),
                .offset_s3(offset_s3), .funct3_s3(funct3_s3),
                .Rs1E(Rs1E), .Rs2E(Rs2E), .RdE(RdE));

// ================================================================ EX
// forwarding muxes (00 = regfile, 01 = WB, 10 = MEM)
mux_32_3in fwd_a (.reset(reset), .a(r_data_1_s3), .b(write_data), .c(result_s4), .s(ForwardAE), .res(true1));
mux_32_3in fwd_b (.reset(reset), .a(r_data_2_s3), .b(write_data), .c(result_s4), .s(ForwardBE), .res(true2));

// operand A: rs1 / PC (AUIPC) / zero (LUI)
wire [31:0] alu_a = (ALUSrcA_s3 == 2'b01) ? next_addr_s3 :
                    (ALUSrcA_s3 == 2'b10) ? 32'd0 : true1;
wire [31:0] alu_b;
mux_32 srcb_mux (.reset(reset), .a(true2), .b(offset_s3), .s(ALUSrc_s3), .res(alu_b));

wire [31:0] alu_result;
wire zero, l_t_u, g_t_u, n_e, l_t_s, g_t_s;
ALU alu (.read_data_1(alu_a), .read_data_2(alu_b), .alucontrol(alucontrol_s3),
         .result(alu_result), .zero(zero), .l_t_u(l_t_u), .g_t_u(g_t_u),
         .n_e(n_e), .l_t_s(l_t_s), .g_t_s(g_t_s));

// branch / jump
wire [31:0] updated_pc;
wire bj;
alu_pc br_target (.reset(reset), .four_pc(next_addr_s3), .offset(offset_s3), .updated_pc(updated_pc));
bj_det bj_unit (.reset(reset), .Branch(Branch_s3), .Jump(Jump_s3), .funct3(funct3_s3),
                .zero(zero), .l_t_u(l_t_u), .g_t_u(g_t_u), .n_e(n_e),
                .l_t_s(l_t_s), .g_t_s(g_t_s), .bj(bj));

// ---- CSRs / interrupts ----
wire [31:0] csr_rdata, mtvec, mepc;
wire        irq_pending;
// Take the interrupt on a valid ID instruction when nothing older is
// redirecting (branch/jump/MRET) or touching CSRs, and the pipe can move.
wire irq_take = irq_pending & valid_s2 & ~stall & ~freeze & ~bj & ~Mret_s3 & ~Csr_s3;

csr_unit csrs (.clk(clk), .reset(reset),
               .csr_en(Csr_s3 & ~freeze), .funct3(funct3_s3), .addr(offset_s3[11:0]),
               .rs1_val(true1), .zimm(Rs1E), .rdata(csr_rdata),
               .irq_ext(irq), .take_irq(irq_take), .trap_pc(next_addr_s2),
               .mret(Mret_s3 & ~freeze), .irq_pending(irq_pending),
               .mtvec(mtvec), .mepc(mepc));

wire [31:0] jalr_target = {alu_result[31:1], 1'b0};
assign pc_next = irq_take   ? mtvec       :
                 Mret_s3    ? mepc        :
                 !bj        ? four_pc     :
                 JumpReg_s3 ? jalr_target : updated_pc;
assign flush = bj | Mret_s3 | irq_take;

// JAL/JALR write PC+4, CSR ops write the old CSR value. Selecting it here
// (not in WB) keeps MEM->EX forwarding correct.
wire [31:0] ex_result = Csr_s3                   ? csr_rdata  :
                        (ResultSrc_s3 == 2'b10)  ? four_pc_s3 : alu_result;

// ---- data bus request (issued from EX) ----
assign dmem_req   = MemRead_s3 | MemWrite_s3;
assign dmem_we    = MemWrite_s3;
assign dmem_addr  = alu_result;
assign freeze     = dmem_req & ~dmem_gnt;

reg [3:0]  st_be;
reg [31:0] st_data;
always @(*) begin
    case (funct3_s3[1:0])
    2'b00: begin // SB
        st_data = {4{true2[7:0]}};
        st_be   = 4'b0001 << alu_result[1:0];
    end
    2'b01: begin // SH
        st_data = {2{true2[15:0]}};
        st_be   = alu_result[1] ? 4'b1100 : 4'b0011;
    end
    default: begin // SW
        st_data = true2;
        st_be   = 4'b1111;
    end
    endcase
end
assign dmem_wdata = st_data;
assign dmem_be    = MemWrite_s3 ? st_be : 4'b1111;

pp_stage_4 pp4 (.clk(clk), .reset(reset), .freeze(freeze),
                .RegWrite_s3(RegWrite_s3), .ResultSrc_s3(ResultSrc_s3),
                .result(ex_result), .funct3_s3(funct3_s3), .RdE(RdE),
                .RegWrite_s4(RegWrite_s4), .ResultSrc_s4(ResultSrc_s4),
                .result_s4(result_s4), .funct3_s4(funct3_s4), .RdM(RdM));

// ================================================================ MEM
// Read data arrives the cycle after the grant. Keep a copy in case the
// pipeline is frozen while this load sits in MEM.
reg        rvalid;
reg [31:0] rdata_q;
always @(posedge clk) begin
    if (reset) rvalid <= 1'b0;
    else       rvalid <= dmem_req & ~dmem_we & dmem_gnt;
    if (rvalid) rdata_q <= dmem_rdata;
end
wire [31:0] mem_word = rvalid ? dmem_rdata : rdata_q;

// little-endian lane select + sign/zero extension (LB/LH/LW/LBU/LHU)
wire [1:0]  byte_off  = result_s4[1:0];
wire [7:0]  ld_byte   = mem_word >> (8 * byte_off);
wire [15:0] ld_half   = byte_off[1] ? mem_word[31:16] : mem_word[15:0];
reg  [31:0] read_data;
always @(*) begin
    case (funct3_s4)
    3'b000:  read_data = {{24{ld_byte[7]}},  ld_byte};  // LB
    3'b001:  read_data = {{16{ld_half[15]}}, ld_half};  // LH
    3'b100:  read_data = {24'd0, ld_byte};              // LBU
    3'b101:  read_data = {16'd0, ld_half};              // LHU
    default: read_data = mem_word;                      // LW
    endcase
end

pp_stage_5 pp5 (.clk(clk), .reset(reset), .freeze(freeze),
                .RegWrite_s4(RegWrite_s4), .ResultSrc_s4(ResultSrc_s4),
                .result_s4(result_s4), .read_data(read_data), .RdM(RdM),
                .RegWrite_s5(RegWrite_s5), .ResultSrc_s5(ResultSrc_s5),
                .result_s5(result_s5), .read_data_s5(read_data_s5), .RdW(RdW));

// ================================================================ WB
assign write_data = (ResultSrc_s5 == 2'b01) ? read_data_s5 : result_s5;

// ================================================================ hazards
hazard_unit hu (.reset(reset),
                .Rs1E(Rs1E), .Rs2E(Rs2E), .RdM(RdM), .RdW(RdW),
                .RegWrite_s4(RegWrite_s4), .RegWrite_s5(RegWrite_s5),
                .ResultSrc_s3(ResultSrc_s3), .RdE(RdE),
                .Rs1D(Rs1D), .Rs2D(Rs2D),
                .ForwardAE(ForwardAE), .ForwardBE(ForwardBE), .stall(stall));

endmodule
