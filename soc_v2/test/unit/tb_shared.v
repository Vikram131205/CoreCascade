`timescale 1ns / 1ps
// ============================================================================
//  Crossbar + the real shared-SRAM banks, wired exactly like soc_top
//  (soc_map.vh, obi_sram with ROW_LSB = 5). Banks are shrunk to BANK_WORDS so
//  the test can compare every word; ITCM, DTCM and the peripheral port get a
//  small obi_sram too, so any request is answered.
// ============================================================================
module tb_shared #(
    parameter BANK_WORDS = 64                 // 8 x 64 words = 2 KB shared window
) (
    input            clk,
    input            reset,
    input  [7:0]     m_req,
    input  [7:0]     m_we,
    input  [31:0]    m_be,
    input  [255:0]   m_addr,
    input  [255:0]   m_wdata,
    output [7:0]     m_gnt,
    output [7:0]     m_rvalid,
    output [255:0]   m_rdata,
    output [7:0]     m_err
);
    localparam NM = 8, NS = 11;
    `include "soc_map.vh"

    wire [NS-1:0]    s_req, s_we, s_gnt, s_rvalid, s_err;
    wire [NS*4-1:0]  s_be;
    wire [NS*32-1:0] s_addr, s_wdata, s_rdata;

    obi_xbar #(.NM(NM), .NS(NS), .SLV_BASE(SLV_BASE), .SLV_MASK(SLV_MASK), .PRIO_M(PRIO_M)) u_xbar (
        .clk(clk), .reset(reset),
        .m_req(m_req), .m_we(m_we), .m_be(m_be), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_gnt(m_gnt), .m_rvalid(m_rvalid), .m_rdata(m_rdata), .m_err(m_err),
        .s_req(s_req), .s_we(s_we), .s_be(s_be), .s_addr(s_addr), .s_wdata(s_wdata),
        .s_gnt(s_gnt), .s_rvalid(s_rvalid), .s_rdata(s_rdata), .s_err(s_err)
    );

    genvar s;
    generate
        for (s = 0; s < NS; s = s + 1) begin : slv
            // slaves 2..9 are the interleaved banks (row = addr[5 +: AW]);
            // 0, 1, 10 are plain word-addressed stand-ins (row = addr[2 +: AW])
            obi_sram #(.WORDS(BANK_WORDS), .ROW_LSB((s >= 2 && s <= 9) ? 5 : 2)) u_mem (
                .clk(clk), .reset(reset),
                .req(s_req[s]), .we(s_we[s]), .be(s_be[s*4 +: 4]),
                .addr(s_addr[s*32 +: 32]), .wdata(s_wdata[s*32 +: 32]),
                .gnt(s_gnt[s]), .rvalid(s_rvalid[s]), .rdata(s_rdata[s*32 +: 32]), .err(s_err[s])
            );
        end
    endgenerate
endmodule
