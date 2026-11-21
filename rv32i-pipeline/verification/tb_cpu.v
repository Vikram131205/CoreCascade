`timescale 1ns / 1ps
// Verification wrapper: core + SRAMs behind an OBI slave model that can
//   - refuse the grant (gnt_block), modelling contention from other masters
//   - delay the response by resp_delay extra cycles (sampled at the grant)
//   - return err for any address with bit 31 set (access-fault testing)
module tb_cpu #(
    parameter IMEM_WORDS = 1024,
    parameter DMEM_WORDS = 1024
) (
    input       clk,
    input       reset,
    input       gnt_block,   // 1 = refuse the data request this cycle
    input [1:0] resp_delay,  // extra response latency for the next grant
    input       irq,         // machine external interrupt
    input       mtip         // machine timer interrupt
);
    wire [31:0] imem_addr, imem_rdata;
    wire        dmem_req, dmem_we;
    wire [3:0]  dmem_be;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire        dmem_gnt, dmem_rvalid, dmem_err;

    rv32i_core u_core (
        .clk(clk), .reset(reset), .irq(irq), .irq_timer(mtip),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_req(dmem_req), .dmem_we(dmem_we), .dmem_be(dmem_be),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_gnt(dmem_gnt), .dmem_rvalid(dmem_rvalid), .dmem_rdata(dmem_rdata), .dmem_err(dmem_err)
    );

    sram_sp #(.WORDS(IMEM_WORDS)) u_imem (
        .clk(clk), .en(1'b1), .we(1'b0), .be(4'b0000),
        .addr(imem_addr[$clog2(IMEM_WORDS)+1:2]), .wdata(32'd0), .rdata(imem_rdata)
    );

    // ---- OBI slave model ----
    reg       busy, err_q;
    reg [1:0] cnt;
    wire resp_now = busy & (cnt == 2'd0);
    assign dmem_gnt = ~gnt_block & (~busy | resp_now);
    wire accept   = dmem_req & dmem_gnt;
    wire err_addr = dmem_addr[31];

    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0;
        end else if (accept) begin
            busy  <= 1'b1;
            cnt   <= resp_delay;
            err_q <= err_addr;
        end else if (resp_now) begin
            busy <= 1'b0;
        end else if (busy) begin
            cnt <= cnt - 2'd1;
        end
    end

    // a refused or faulting request must not touch memory
    wire [31:0] sram_rdata;
    sram_sp #(.WORDS(DMEM_WORDS)) u_dmem (
        .clk(clk), .en(accept & ~err_addr), .we(dmem_we), .be(dmem_be),
        .addr(dmem_addr[$clog2(DMEM_WORDS)+1:2]), .wdata(dmem_wdata), .rdata(sram_rdata)
    );

    // rdata is only valid with rvalid; drive garbage otherwise
    assign dmem_rvalid = resp_now;
    assign dmem_err    = resp_now & err_q;
    assign dmem_rdata  = (resp_now & ~err_q) ? sram_rdata : 32'hDEADBEEF;
endmodule
