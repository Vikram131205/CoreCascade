`timescale 1ns / 1ps
// ============================================================================
//  CPU subsystem: RV32IM core + private ITCM / DTCM
// ============================================================================
//            fetch (port A, 1 cycle)                 data
//   ITCM  <────────────────────────── core ──────────────┬──> DTCM port A
//    │ port B                                             │    (0x1xxx_xxxx,
//    └─ crossbar slave (loader writes,                    │     always granted)
//       CPU reads constants via the crossbar)             └──> OBI master
//   DTCM port B ─ crossbar slave (loader writes .data)        (everything else)
//
//  The CPU's code fetch and its private data never touch the crossbar, so the
//  CPU keeps running at full speed while the GPU, display and loader use it.
// ============================================================================
module cpu_subsys #(
    parameter ITCM_WORDS = 8192,          // 32 KB
    parameter DTCM_WORDS = 4096           // 16 KB
) (
    input             clk,
    input             reset,              // CPU reset (held while booting)
    input             mem_reset,          // memory-side reset (system reset)
    input             irq_ext,
    input             irq_timer,

    // OBI master (shared SRAM, peripherals, ITCM reads)
    output            m_req,
    output            m_we,
    output     [3:0]  m_be,
    output     [31:0] m_addr,
    output     [31:0] m_wdata,
    input             m_gnt,
    input             m_rvalid,
    input      [31:0] m_rdata,
    input             m_err,

    // OBI slave: ITCM port B
    input             si_req,
    input             si_we,
    input      [3:0]  si_be,
    input      [31:0] si_addr,
    input      [31:0] si_wdata,
    output            si_gnt,
    output reg        si_rvalid,
    output     [31:0] si_rdata,
    output            si_err,

    // OBI slave: DTCM port B
    input             sd_req,
    input             sd_we,
    input      [3:0]  sd_be,
    input      [31:0] sd_addr,
    input      [31:0] sd_wdata,
    output            sd_gnt,
    output reg        sd_rvalid,
    output     [31:0] sd_rdata,
    output            sd_err
);
    localparam IAW = $clog2(ITCM_WORDS);
    localparam DAW = $clog2(DTCM_WORDS);

    wire [31:0] imem_addr, imem_rdata;
    wire        d_req, d_we, d_gnt, d_rvalid, d_err;
    wire [3:0]  d_be;
    wire [31:0] d_addr, d_wdata, d_rdata;

    rv32i_core u_core (
        .clk(clk), .reset(reset), .irq(irq_ext), .irq_timer(irq_timer),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_req(d_req), .dmem_we(d_we), .dmem_be(d_be),
        .dmem_addr(d_addr), .dmem_wdata(d_wdata),
        .dmem_gnt(d_gnt), .dmem_rvalid(d_rvalid), .dmem_rdata(d_rdata), .dmem_err(d_err)
    );

    // ---- data port split: DTCM locally, everything else on the crossbar ----
    wire is_dtcm   = (d_addr[31:28] == 4'h1);
    wire dtcm_ok   = (d_addr[27:2] < DTCM_WORDS);
    wire local_acc = d_req & is_dtcm;

    reg  local_rvalid, local_err;
    always @(posedge clk) begin
        local_rvalid <= !mem_reset & local_acc;
        local_err    <= ~dtcm_ok;
    end

    assign m_req   = d_req & ~is_dtcm;
    assign m_we    = d_we;
    assign m_be    = d_be;
    assign m_addr  = d_addr;
    assign m_wdata = d_wdata;

    wire [31:0] dtcm_a_rdata;
    assign d_gnt    = is_dtcm ? 1'b1 : m_gnt;
    assign d_rvalid = local_rvalid | m_rvalid;
    assign d_rdata  = local_rvalid ? dtcm_a_rdata : m_rdata;
    assign d_err    = local_rvalid ? local_err    : m_err;

    // ---- ITCM: port A = fetch, port B = crossbar ----
    assign si_gnt = 1'b1;
    assign si_err = 1'b0;
    always @(posedge clk) si_rvalid <= !mem_reset & si_req;
    sram_dp #(.WORDS(ITCM_WORDS)) u_itcm (
        .clk(clk),
        .a_en(1'b1), .a_we(1'b0), .a_be(4'b0000), .a_addr(imem_addr[IAW+1:2]),
        .a_wdata(32'd0), .a_rdata(imem_rdata),
        .b_en(si_req), .b_we(si_we), .b_be(si_be), .b_addr(si_addr[IAW+1:2]),
        .b_wdata(si_wdata), .b_rdata(si_rdata)
    );

    // ---- DTCM: port A = CPU data, port B = crossbar ----
    assign sd_gnt = 1'b1;
    assign sd_err = 1'b0;
    always @(posedge clk) sd_rvalid <= !mem_reset & sd_req;
    sram_dp #(.WORDS(DTCM_WORDS)) u_dtcm (
        .clk(clk),
        .a_en(local_acc & dtcm_ok), .a_we(d_we), .a_be(d_be), .a_addr(d_addr[DAW+1:2]),
        .a_wdata(d_wdata), .a_rdata(dtcm_a_rdata),
        .b_en(sd_req), .b_we(sd_we), .b_be(sd_be), .b_addr(sd_addr[DAW+1:2]),
        .b_wdata(sd_wdata), .b_rdata(sd_rdata)
    );
endmodule
