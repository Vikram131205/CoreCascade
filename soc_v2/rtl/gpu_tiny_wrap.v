`timescale 1ns / 1ps
// ============================================================================
//  tiny-gpu (unmodified) as a bus master on shared SRAM
// ============================================================================
//  - Program memory: local 256 x 16-bit RAM, written by the command processor
//    while the GPU is held in reset, read by tiny-gpu's fetchers.
//  - Data memory: each of tiny-gpu's NCH data channels becomes one OBI master
//    port. tiny-gpu's 8-bit address a is mapped into shared SRAM:
//        word mode : data_base + 4*a   (one element per 32-bit word; neighbours
//                                       land in different banks -> parallel)
//        byte mode : data_base + a     (packed bytes, e.g. an 8-bpp framebuffer)
//  - tiny-gpu holds *_valid until it sees *_ready; the adapter issues one OBI
//    request, waits for rvalid and answers with a single-cycle ready.
// ============================================================================
module gpu_tiny_wrap #(
    parameter NCH = 4                        // tiny-gpu data channels = OBI ports
) (
    input                  clk,
    input                  reset,            // system reset | command-processor reset

    // control from the command processor
    input                  start,
    output                 done,
    input                  dcr_we,
    input      [7:0]       dcr_data,
    input                  pw_en,            // program RAM write
    input      [7:0]       pw_addr,
    input      [15:0]      pw_data,
    input      [31:0]      data_base,
    input                  byte_mode,
    output                 outstanding,      // a data access is in flight
    output reg             bus_err,          // sticky until reset

    // OBI masters (one per data channel)
    output     [NCH-1:0]    d_req,
    output     [NCH-1:0]    d_we,
    output     [NCH*4-1:0]  d_be,
    output     [NCH*32-1:0] d_addr,
    output     [NCH*32-1:0] d_wdata,
    input      [NCH-1:0]    d_gnt,
    input      [NCH-1:0]    d_rvalid,
    input      [NCH*32-1:0] d_rdata,
    input      [NCH-1:0]    d_err
);
    // ---------------------------------------------------------------- tiny-gpu
    wire        p_valid;
    wire [7:0]  p_addr;
    reg         p_ready;
    wire [15:0] p_rdata;

    wire [NCH-1:0]   g_rvalid, g_wvalid;
    wire [NCH*8-1:0] g_raddr, g_waddr, g_wdata;
    wire [NCH-1:0]   g_rready, g_wready;
    wire [NCH*8-1:0] g_rdata;

    gpu #(
        .DATA_MEM_ADDR_BITS(8),
        .DATA_MEM_DATA_BITS(8),
        .DATA_MEM_NUM_CHANNELS(NCH),
        .PROGRAM_MEM_ADDR_BITS(8),
        .PROGRAM_MEM_DATA_BITS(16),
        .PROGRAM_MEM_NUM_CHANNELS(1),
        .NUM_CORES(2),
        .THREADS_PER_BLOCK(4)
    ) u_gpu (
        .clk(clk),
        .reset(reset),
        .start(start),
        .done(done),
        .device_control_write_enable(dcr_we),
        .device_control_data(dcr_data),
        .program_mem_read_valid(p_valid),
        .program_mem_read_address(p_addr),
        .program_mem_read_ready(p_ready),
        .program_mem_read_data(p_rdata),
        .data_mem_read_valid(g_rvalid),
        .data_mem_read_address(g_raddr),
        .data_mem_read_ready(g_rready),
        .data_mem_read_data(g_rdata),
        .data_mem_write_valid(g_wvalid),
        .data_mem_write_address(g_waddr),
        .data_mem_write_data(g_wdata),
        .data_mem_write_ready(g_wready)
    );

    // ---------------------------------------------------------------- program RAM
    reg  [15:0] pram [0:255];
    reg  [15:0] pram_q;
    wire        p_fire = p_valid & ~p_ready;
    always @(posedge clk) begin
        if (pw_en) pram[pw_addr] <= pw_data;
        else if (p_fire) pram_q <= pram[p_addr];
        p_ready <= !reset & p_fire;
    end
    assign p_rdata = pram_q;

    // ---------------------------------------------------------------- data channels
    localparam IDLE = 2'd0, REQ = 2'd1, WAIT = 2'd2;
    wire [NCH-1:0] busy;
    genvar c;
    generate
        for (c = 0; c < NCH; c = c + 1) begin : ch
            reg  [1:0]  st;
            reg         is_wr;
            reg  [7:0]  a8, wd8;
            wire [31:0] word_addr = data_base + {22'd0, a8, 2'b00};
            wire [31:0] byte_addr = data_base + {24'd0, a8};
            wire [31:0] addr      = byte_mode ? byte_addr : word_addr;
            wire [1:0]  lane      = byte_addr[1:0];
            wire [31:0] rword     = d_rdata[c*32 +: 32];
            wire        resp      = (st == WAIT) & d_rvalid[c];

            assign busy[c]             = (st != IDLE);
            assign d_req[c]            = (st == REQ);
            assign d_we[c]             = is_wr;
            assign d_be[c*4 +: 4]      = (is_wr & byte_mode) ? (4'b0001 << lane) : 4'b1111;
            assign d_addr[c*32 +: 32]  = byte_mode ? addr : {addr[31:2], 2'b00};
            assign d_wdata[c*32 +: 32] = byte_mode ? {4{wd8}} : {24'd0, wd8};

            assign g_rready[c]         = resp & ~is_wr;
            assign g_wready[c]         = resp &  is_wr;
            assign g_rdata[c*8 +: 8]   = byte_mode ? (rword >> (8 * lane)) : rword[7:0];

            always @(posedge clk) begin
                if (reset) begin
                    st <= IDLE;
                end else begin
                    case (st)
                        IDLE: if (g_rvalid[c]) begin
                            is_wr <= 1'b0;
                            a8    <= g_raddr[c*8 +: 8];
                            st    <= REQ;
                        end else if (g_wvalid[c]) begin
                            is_wr <= 1'b1;
                            a8    <= g_waddr[c*8 +: 8];
                            wd8   <= g_wdata[c*8 +: 8];
                            st    <= REQ;
                        end
                        REQ:  if (d_gnt[c]) st <= WAIT;
                        WAIT: if (d_rvalid[c]) st <= IDLE;
                        default: st <= IDLE;
                    endcase
                end
            end
        end
    endgenerate

    assign outstanding = |busy;
    always @(posedge clk) begin
        if (reset) bus_err <= 1'b0;
        else if (|(d_rvalid & d_err)) bus_err <= 1'b1;
    end
endmodule
