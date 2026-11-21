`timescale 1ns / 1ps
// ============================================================================
//  Standalone RV32IM system: core + private instruction and data SRAM.
//  (The SoC uses rv32i_core through cpu_subsys - see soc_v2/rtl.)
// ============================================================================
module top_module #(
    parameter IMEM_WORDS = 256,        // 1 KB
    parameter DMEM_WORDS = 256,        // 1 KB
    parameter IMEM_INIT  = "",
    parameter DMEM_INIT  = ""
) (
    input clk,
    input reset,
    input irq,
    input irq_timer
);
    wire [31:0] imem_addr, imem_rdata;
    wire        dmem_req, dmem_we;
    wire [3:0]  dmem_be;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    reg         dmem_rvalid;

    // the data SRAM always grants and answers one cycle later
    always @(posedge clk) dmem_rvalid <= !reset & dmem_req;

    rv32i_core u_core (
        .clk(clk), .reset(reset), .irq(irq), .irq_timer(irq_timer),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_req(dmem_req), .dmem_we(dmem_we), .dmem_be(dmem_be),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_gnt(1'b1), .dmem_rvalid(dmem_rvalid), .dmem_rdata(dmem_rdata), .dmem_err(1'b0)
    );

    sram_sp #(.WORDS(IMEM_WORDS), .INIT_FILE(IMEM_INIT)) u_imem (
        .clk(clk), .en(1'b1), .we(1'b0), .be(4'b0000),
        .addr(imem_addr[$clog2(IMEM_WORDS)+1:2]), .wdata(32'd0), .rdata(imem_rdata)
    );

    sram_sp #(.WORDS(DMEM_WORDS), .INIT_FILE(DMEM_INIT)) u_dmem (
        .clk(clk), .en(dmem_req), .we(dmem_we), .be(dmem_be),
        .addr(dmem_addr[$clog2(DMEM_WORDS)+1:2]), .wdata(dmem_wdata), .rdata(dmem_rdata)
    );
endmodule
