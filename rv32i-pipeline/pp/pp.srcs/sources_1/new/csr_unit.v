`timescale 1ns / 1ps
// ============================================================================
//  Machine-mode CSRs, trap entry/return and interrupt state (EX stage)
// ============================================================================
//  Implemented (everything else reads 0, writes ignored):
//    0x300 mstatus   MIE(3), MPIE(7), MPP(12:11) reads as 11
//    0x301 misa      RV32IM, read-only
//    0x304 mie       MTIE(7), MEIE(11)
//    0x305 mtvec     direct mode, [1:0] forced to 0
//    0x340 mscratch
//    0x341 mepc      [1:0] forced to 0
//    0x342 mcause
//    0x343 mtval
//    0x344 mip       MTIP(7), MEIP(11) read-only (driven by the timer / IRQ ctrl)
//    0xB00/0xB80 mcycle(h), 0xB02/0xB82 minstret(h)        read-only counters
//    0xC00/0xC80 cycle(h),  0xC02/0xC82 instret(h)         user aliases
//    0xF14 mhartid   0
//  Traps: synchronous exceptions (cause/tval supplied by the core) and the
//  machine external (11) / timer (7) interrupts; external has priority.
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

    // trap entry / return
    input             take_trap,    // enter the trap handler this cycle
    input             trap_is_irq,  // interrupt (cause from irq_cause) vs exception
    input      [3:0]  trap_cause,   // exception code
    input      [31:0] trap_pc,      // mepc
    input      [31:0] trap_val,     // mtval for exceptions
    input             mret,         // MRET in EX (pipeline advancing)

    // interrupt lines (level-sensitive)
    input             irq_ext,
    input             irq_timer,
    output            irq_pending,

    input             retire,       // one instruction left WB this cycle
    output     [31:0] mtvec,
    output     [31:0] mepc
);
    reg        mstatus_mie, mstatus_mpie, mie_meie, mie_mtie;
    reg [31:0] mtvec_q, mscratch, mepc_q, mcause, mtval;
    reg [63:0] mcycle, minstret;

    assign mtvec = mtvec_q;
    assign mepc  = mepc_q;

    wire ext_en   = irq_ext   & mie_meie;
    wire timer_en = irq_timer & mie_mtie;
    assign irq_pending = mstatus_mie & (ext_en | timer_en);
    wire [31:0] irq_cause = ext_en ? 32'h8000000B : 32'h80000007;

    wire [31:0] mstatus = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};

    always @(*) begin
        case (addr)
            12'h300: rdata = mstatus;
            12'h301: rdata = 32'h40001100;                       // MXL=1, I + M
            12'h304: rdata = {20'd0, mie_meie, 3'd0, mie_mtie, 7'd0};
            12'h305: rdata = mtvec_q;
            12'h340: rdata = mscratch;
            12'h341: rdata = mepc_q;
            12'h342: rdata = mcause;
            12'h343: rdata = mtval;
            12'h344: rdata = {20'd0, irq_ext, 3'd0, irq_timer, 7'd0};
            12'hB00, 12'hC00: rdata = mcycle[31:0];
            12'hB80, 12'hC80: rdata = mcycle[63:32];
            12'hB02, 12'hC02: rdata = minstret[31:0];
            12'hB82, 12'hC82: rdata = minstret[63:32];
            default: rdata = 32'd0;
        endcase
    end

    // CSRRW(I) / CSRRS(I) / CSRRC(I)
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
            mie_mtie     <= 1'b0;
            mtvec_q      <= 32'd0;
            mscratch     <= 32'd0;
            mepc_q       <= 32'd0;
            mcause       <= 32'd0;
            mtval        <= 32'd0;
            mcycle       <= 64'd0;
            minstret     <= 64'd0;
        end else begin
            mcycle <= mcycle + 64'd1;
            if (retire) minstret <= minstret + 64'd1;

            if (take_trap) begin
                mepc_q       <= {trap_pc[31:2], 2'b00};
                mcause       <= trap_is_irq ? irq_cause : {28'd0, trap_cause};
                mtval        <= trap_is_irq ? 32'd0 : trap_val;
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
                    12'h304: begin
                        mie_meie <= wdata[11];
                        mie_mtie <= wdata[7];
                    end
                    12'h305: mtvec_q  <= {wdata[31:2], 2'b00};
                    12'h340: mscratch <= wdata;
                    12'h341: mepc_q   <= {wdata[31:2], 2'b00};
                    12'h342: mcause   <= wdata;
                    12'h343: mtval    <= wdata;
                    default: ;
                endcase
            end
        end
    end
endmodule
