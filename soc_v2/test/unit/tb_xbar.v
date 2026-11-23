`timescale 1ns / 1ps
// ============================================================================
//  obi_xbar exactly as soc_top instantiates it (same soc_map.vh), with every
//  master and slave port brought out so test_xbar.py can drive and model them.
// ============================================================================
module tb_xbar (
    input            clk,
    input            reset,
    // masters (Python = CPU, boot loader, GPU x4, command processor, display)
    input  [7:0]     m_req,
    input  [7:0]     m_we,
    input  [31:0]    m_be,
    input  [255:0]   m_addr,
    input  [255:0]   m_wdata,
    output [7:0]     m_gnt,
    output [7:0]     m_rvalid,
    output [255:0]   m_rdata,
    output [7:0]     m_err,
    // slaves (Python = ITCM, DTCM, 8 banks, peripheral bridge)
    output [10:0]    s_req,
    output [10:0]    s_we,
    output [43:0]    s_be,
    output [351:0]   s_addr,
    output [351:0]   s_wdata,
    input  [10:0]    s_gnt,
    input  [10:0]    s_rvalid,
    input  [351:0]   s_rdata,
    input  [10:0]    s_err
);
    localparam NM = 8, NS = 11;
    `include "soc_map.vh"

    obi_xbar #(.NM(NM), .NS(NS), .SLV_BASE(SLV_BASE), .SLV_MASK(SLV_MASK), .PRIO_M(PRIO_M)) u_xbar (
        .clk(clk), .reset(reset),
        .m_req(m_req), .m_we(m_we), .m_be(m_be), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_gnt(m_gnt), .m_rvalid(m_rvalid), .m_rdata(m_rdata), .m_err(m_err),
        .s_req(s_req), .s_we(s_we), .s_be(s_be), .s_addr(s_addr), .s_wdata(s_wdata),
        .s_gnt(s_gnt), .s_rvalid(s_rvalid), .s_rdata(s_rdata), .s_err(s_err)
    );
endmodule
