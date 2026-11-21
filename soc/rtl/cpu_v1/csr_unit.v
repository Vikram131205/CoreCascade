`timescale 1ns / 1ps
// ============================================================================
//  Machine-mode CSRs + external interrupt state (EX stage)
// ============================================================================
//  Implemented (everything else reads 0, writes ignored):
//    0x300 mstatus   MIE(3), MPIE(7), MPP(12:11) reads as 11
//    0x301 misa      RV32I, read-only
//    0x304 mie       MEIE(11)
//    0x305 mtvec     direct mode, [1:0] forced to 0
//    0x340 mscratch
//    0x341 mepc      [1:0] forced to 0
//    0x342 mcause
//    0x344 mip       MEIP(11) = external interrupt line, read-only
//    0xB00 mcycle / 0xC00 cycle   free-running cycle counter, read-only
//    0xF14 mhartid   0
//  Trap sources: machine external interrupt only (mcause = 0x8000000B).
// ============================================================================
module csr_unit (
    input             clk,
    input             reset,

    // CSR instruction in EX (only asserted when the pipeline advances)
    input             csr_en,
    input      [2:0]  funct3,
    input      [11:0] addr,
    input      [31:0] rs1_val,
    input      [4:0]  zimm,
    output reg [31:0] rdata,

    // interrupts
    input             irq_ext,      // level-sensitive external interrupt
    input             take_irq,     // core is entering the trap this cycle
    input      [31:0] trap_pc,      // PC of the interrupted instruction
    input             mret,         // MRET in EX (pipeline advancing)
    output            irq_pending,
    output     [31:0] mtvec,
    output     [31:0] mepc
);
    reg        mstatus_mie, mstatus_mpie, mie_meie;
    reg [31:0] mtvec_q, mscratch, mepc_q, mcause, mcycle;

    assign mtvec       = mtvec_q;
    assign mepc        = mepc_q;
    assign irq_pending = mstatus_mie & mie_meie & irq_ext;

    wire [31:0] mstatus = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};

    // read (combinational, old value goes to rd)
    always @(*) begin
        case (addr)
            12'h300: rdata = mstatus;
            12'h301: rdata = 32'h40000100;
            12'h304: rdata = {20'd0, mie_meie, 11'd0};
            12'h305: rdata = mtvec_q;
            12'h340: rdata = mscratch;
            12'h341: rdata = mepc_q;
            12'h342: rdata = mcause;
            12'h344: rdata = {20'd0, irq_ext, 11'd0};
            12'hB00, 12'hC00: rdata = mcycle;
            default: rdata = 32'd0;
        endcase
    end

    // write value: CSRRW(I) / CSRRS(I) / CSRRC(I)
    wire [31:0] src = funct3[2] ? {27'd0, zimm} : rs1_val;
    reg  [31:0] wdata;
    always @(*) begin
        case (funct3[1:0])
            2'b01:   wdata = src;
            2'b10:   wdata = rdata | src;
            2'b11:   wdata = rdata & ~src;
            default: wdata = rdata;
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mie_meie     <= 1'b0;
            mtvec_q      <= 32'd0;
            mscratch     <= 32'd0;
            mepc_q       <= 32'd0;
            mcause       <= 32'd0;
            mcycle       <= 32'd0;
        end else begin
            mcycle <= mcycle + 32'd1;

            if (take_irq) begin
                mepc_q       <= trap_pc;
                mcause       <= 32'h8000000B;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (mret) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (csr_en) begin
                case (addr)
                    12'h300: begin
                        mstatus_mie  <= wdata[3];
                        mstatus_mpie <= wdata[7];
                    end
                    12'h304: mie_meie <= wdata[11];
                    12'h305: mtvec_q  <= {wdata[31:2], 2'b00};
                    12'h340: mscratch <= wdata;
                    12'h341: mepc_q   <= {wdata[31:2], 2'b00};
                    12'h342: mcause   <= wdata;
                    default: ;
                endcase
            end
        end
    end
endmodule
