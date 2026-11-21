`timescale 1ns / 1ps
// ============================================================================
//  Peripheral bridge: one OBI slave in front of NP register blocks.
//  Peripheral i lives at 0x4000_0000 + i * 0x1000 (addr[15:12] = i).
//  Register-block convention:
//    p_req[i]  : access request (the bridge has decoded the block)
//    p_ready[i]: block can take it now (UART TX may hold the bus off)
//    the block acts on p_req & p_ready and registers its read data, which the
//    bridge returns with rvalid one cycle later.
//  Unknown blocks answer with err.
// ============================================================================
module periph_bridge #(
    parameter NP = 6
) (
    input                 clk,
    input                 reset,
    // OBI slave
    input                 req,
    input                 we,
    input      [3:0]      be,
    input      [31:0]     addr,
    input      [31:0]     wdata,
    output                gnt,
    output reg            rvalid,
    output     [31:0]     rdata,
    output                err,
    // register blocks
    output     [NP-1:0]   p_req,
    output                p_we,
    output     [3:0]      p_be,
    output     [11:0]     p_addr,
    output     [31:0]     p_wdata,
    input      [NP-1:0]   p_ready,
    input      [NP*32-1:0] p_rdata
);
    wire [3:0] idx   = addr[15:12];
    wire       valid = (idx < NP);

    genvar i;
    generate
        for (i = 0; i < NP; i = i + 1) begin : dec
            assign p_req[i] = req & valid & (idx == i);
        end
    endgenerate
    assign p_we    = we;
    assign p_be    = be;
    assign p_addr  = addr[11:0];
    assign p_wdata = wdata;
    assign gnt     = valid ? p_ready[idx] : 1'b1;

    reg [3:0] rsp_idx;
    reg       rsp_err;
    always @(posedge clk) begin
        rvalid <= !reset & req & gnt;
        if (req & gnt) begin
            rsp_idx <= idx;
            rsp_err <= ~valid;
        end
    end
    assign rdata = rsp_err ? 32'd0 : p_rdata[rsp_idx*32 +: 32];
    assign err   = rvalid & rsp_err;
endmodule
