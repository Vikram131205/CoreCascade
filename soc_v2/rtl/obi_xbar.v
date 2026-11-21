`timescale 1ns / 1ps
// ============================================================================
//  OBI crossbar: NM masters x NS slaves, transfers to different slaves in
//  parallel in the same cycle.
// ============================================================================
//  OBI subset used everywhere in the SoC:
//    request : req, we, be[3:0], addr[31:0], wdata[31:0]  held until gnt
//    response: rvalid, rdata[31:0], err                   (reads and writes)
//  Rules
//    - A slave s is hit when (addr & SLV_MASK[s]) == SLV_BASE[s].
//    - Each slave has its own arbiter: master PRIO_M (if < NM) wins whenever
//      it requests, otherwise round-robin after the last winner.
//    - A slave holds at most one outstanding transaction: it can accept a new
//      request in the same cycle its previous response returns.
//    - owner[s] remembers which master gets slave s's response.
//    - Requests that hit no slave are granted and answered next cycle with err.
//  Masters must keep at most one transaction outstanding (all of ours do).
// ============================================================================
module obi_xbar #(
    parameter NM = 8,
    parameter NS = 11,
    parameter [NS*32-1:0] SLV_BASE = {NS{32'h0}},
    parameter [NS*32-1:0] SLV_MASK = {NS{32'h0}},
    parameter PRIO_M = NM                     // NM = no priority master
) (
    input                    clk,
    input                    reset,
    // masters
    input      [NM-1:0]      m_req,
    input      [NM-1:0]      m_we,
    input      [NM*4-1:0]    m_be,
    input      [NM*32-1:0]   m_addr,
    input      [NM*32-1:0]   m_wdata,
    output reg [NM-1:0]      m_gnt,
    output reg [NM-1:0]      m_rvalid,
    output reg [NM*32-1:0]   m_rdata,
    output reg [NM-1:0]      m_err,
    // slaves
    output reg [NS-1:0]      s_req,
    output reg [NS-1:0]      s_we,
    output reg [NS*4-1:0]    s_be,
    output reg [NS*32-1:0]   s_addr,
    output reg [NS*32-1:0]   s_wdata,
    input      [NS-1:0]      s_gnt,
    input      [NS-1:0]      s_rvalid,
    input      [NS*32-1:0]   s_rdata,
    input      [NS-1:0]      s_err
);
    localparam MW = (NM > 1) ? $clog2(NM) : 1;

    // ---------------------------------------------------------------- decode
    reg [NM*NS-1:0] hit;          // hit[m*NS+s]
    reg [NM-1:0]    mapped;
    integer dm, ds, ak, as_, ai, rm, rs, ri, qm, qs, qi, fm, fs;
    always @(*) begin
        for (dm = 0; dm < NM; dm = dm + 1) begin
            mapped[dm] = 1'b0;
            for (ds = 0; ds < NS; ds = ds + 1) begin
                hit[dm*NS+ds] = ((m_addr[dm*32 +: 32] & SLV_MASK[ds*32 +: 32]) == SLV_BASE[ds*32 +: 32]);
                mapped[dm]   = mapped[dm] | hit[dm*NS+ds];
            end
        end
    end

    // ---------------------------------------------------------------- state
    reg [NS-1:0]    busy;         // slave has an outstanding response
    reg [NS*MW-1:0] owner;        // master that owns that response
    reg [NS*MW-1:0] last;         // last winner, for round-robin
    reg [NM-1:0]    err_rsp;      // pending error response per master

    // ---------------------------------------------------------------- arbitration
    reg [NS*MW-1:0] win;
    reg [NS-1:0]    any;
    always @(*) begin
        ak = 0;
        ai = 0;
        for (as_ = 0; as_ < NS; as_ = as_ + 1) begin
            any[as_] = 1'b0;
            win[as_*MW +: MW] = {MW{1'b0}};
            if (PRIO_M < NM && m_req[PRIO_M] && hit[PRIO_M*NS+as_]) begin
                any[as_] = 1'b1;
                win[as_*MW +: MW] = PRIO_M;
            end else begin
                for (ak = 1; ak <= NM; ak = ak + 1) begin
                    ai = last[as_*MW +: MW] + ak;
                    if (ai >= NM) ai = ai - NM;
                    if (!any[as_] && m_req[ai] && hit[ai*NS+as_]) begin
                        any[as_] = 1'b1;
                        win[as_*MW +: MW] = ai;
                    end
                end
            end
        end
    end

    // ---------------------------------------------------------------- request path
    always @(*) begin
        for (rs = 0; rs < NS; rs = rs + 1) begin
            ri = win[rs*MW +: MW];
            s_req[rs]            = any[rs] & (~busy[rs] | s_rvalid[rs]);
            s_we[rs]             = m_we[ri];
            s_be[rs*4 +: 4]      = m_be[ri*4 +: 4];
            s_addr[rs*32 +: 32]  = m_addr[ri*32 +: 32];
            s_wdata[rs*32 +: 32] = m_wdata[ri*32 +: 32];
        end
        for (rm = 0; rm < NM; rm = rm + 1)
            m_gnt[rm] = m_req[rm] & ~mapped[rm] & ~err_rsp[rm];        // error responder
        for (rs = 0; rs < NS; rs = rs + 1)
            if (s_req[rs] & s_gnt[rs])
                m_gnt[win[rs*MW +: MW]] = 1'b1;
    end

    // ---------------------------------------------------------------- response path
    always @(*) begin
        qi = 0;
        for (qm = 0; qm < NM; qm = qm + 1) begin
            m_rvalid[qm]         = err_rsp[qm];
            m_err[qm]            = err_rsp[qm];
            m_rdata[qm*32 +: 32] = 32'd0;
        end
        for (qs = 0; qs < NS; qs = qs + 1) begin
            if (s_rvalid[qs]) begin
                qi = owner[qs*MW +: MW];
                m_rvalid[qi]         = 1'b1;
                m_err[qi]            = m_err[qi] | s_err[qs];
                m_rdata[qi*32 +: 32] = s_rdata[qs*32 +: 32];
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            busy    <= {NS{1'b0}};
            owner   <= {(NS*MW){1'b0}};
            last    <= {(NS*MW){1'b0}};
            err_rsp <= {NM{1'b0}};
        end else begin
            for (fs = 0; fs < NS; fs = fs + 1) begin
                if (s_req[fs] & s_gnt[fs]) begin
                    busy[fs]            <= 1'b1;
                    owner[fs*MW +: MW]  <= win[fs*MW +: MW];
                    last[fs*MW +: MW]   <= win[fs*MW +: MW];
                end else if (s_rvalid[fs]) begin
                    busy[fs] <= 1'b0;
                end
            end
            for (fm = 0; fm < NM; fm = fm + 1)
                err_rsp[fm] <= m_req[fm] & ~mapped[fm] & ~err_rsp[fm];
        end
    end
endmodule
