`timescale 1ns / 1ps
// ============================================================================
//  GPU command processor, registers at 0x4000_4000
// ============================================================================
//  The CPU queues launch descriptors in a ring buffer in shared SRAM and bumps
//  Q_TAIL; the command processor runs them in order, without the CPU.
//
//  Registers
//    +0x00 CTRL        RW  bit0 ENABLE
//    +0x04 Q_BASE      RW  ring base (32-byte aligned, in shared SRAM)
//    +0x08 Q_SIZE      RW  ring entries (power of two)
//    +0x0C Q_HEAD      R   descriptors consumed (free-running counter)
//    +0x10 Q_TAIL      RW  descriptors queued   (free-running counter)
//    +0x14 STATUS      R   bit0 busy, bit1 error, [7:4] error code,
//                          [31:16] index (Q_HEAD) of the failing descriptor
//    +0x18 TIMEOUT     RW  watchdog in cycles per launch (0 = off)
//    +0x1C LAST_FENCE  R   fence value of the last completed launch
//    +0x20 KCYCLES     R   cycles the last kernel ran
//    +0x24 ERR_CLR     W   clear the error and skip the failing descriptor
//    +0x28 LAUNCHES    R   completed launches
//    +0x2C LOADS       R   kernel loads performed (reloads are skipped)
//  Error codes: 1 bad descriptor, 2 timeout, 3 bus error (CP), 4 bus error (GPU)
//
//  Descriptor (8 words, 32 bytes) for the tiny-gpu back end
//    0 kernel_addr   1 kernel_words (1..256)   2 threads (1..255)
//    3 data_base     4 arg_ptr (reserved for GPU v2)
//    5 fence_addr    6 fence_value
//    7 flags: bit0 irq on completion, bit1 force kernel reload, bit2 byte mode
// ============================================================================
module gpu_cp (
    input             clk,
    input             reset,

    // registers (peripheral bridge)
    input             p_req,
    input             p_we,
    input      [11:0] p_addr,
    input      [31:0] p_wdata,
    output            p_ready,
    output reg [31:0] p_rdata,

    // OBI master: descriptor + kernel fetch, fence write
    output reg        m_req,
    output reg        m_we,
    output     [3:0]  m_be,
    output reg [31:0] m_addr,
    output reg [31:0] m_wdata,
    input             m_gnt,
    input             m_rvalid,
    input      [31:0] m_rdata,
    input             m_err,

    // GPU control
    output            gpu_reset,      // command-processor soft reset of the GPU
    output reg        gpu_start,
    input             gpu_done,
    output reg        dcr_we,
    output     [7:0]  dcr_data,
    output reg        pw_en,
    output reg [7:0]  pw_addr,
    output reg [15:0] pw_data,
    output     [31:0] data_base,
    output            byte_mode,
    input             gpu_outstanding,
    input             gpu_bus_err,

    // interrupts
    output reg        irq_fence,      // one-cycle pulse per completed launch (if flagged)
    output            irq_err         // level while in error
);
    localparam S_IDLE = 4'd0, S_FETCH = 4'd1, S_CHECK = 4'd2, S_LOAD = 4'd3,
               S_GRST = 4'd4, S_DCR = 4'd5, S_START = 4'd10, S_RUN = 4'd6, S_FENCE = 4'd7,
               S_DONE = 4'd8, S_ERR = 4'd9;

    reg [3:0]  state;
    reg        waiting;                  // OBI: request granted, response pending
    reg        enable, err;
    reg [3:0]  err_code;
    reg [31:0] q_base, q_size, q_head, q_tail, timeout;
    reg [31:0] last_fence, kcycles, launches, loads;
    reg [31:0] d [0:7];
    reg [2:0]  fi;                       // descriptor word index
    reg [8:0]  li;                       // kernel word index
    reg [31:0] loaded_addr;
    reg        loaded_valid;

    assign p_ready   = 1'b1;
    assign m_be      = 4'b1111;
    assign dcr_data  = d[2][7:0];
    assign data_base = d[3];
    assign byte_mode = d[7][2];
    assign irq_err   = err;
    // GPU runs only between DCR write and completion; reset otherwise
    assign gpu_reset = !(state == S_DCR || state == S_START || state == S_RUN || state == S_FENCE);
    wire   err_clr   = p_req & p_we & (p_addr[5:2] == 4'd9) & (state == S_ERR);

    wire [31:0] slot = q_base + (((q_head & (q_size - 32'd1))) << 5);

    // ---------------------------------------------------------------- registers
    always @(posedge clk) begin
        if (p_req & ~p_we) begin
            case (p_addr[5:2])
                4'd0:  p_rdata <= {31'd0, enable};
                4'd1:  p_rdata <= q_base;
                4'd2:  p_rdata <= q_size;
                4'd3:  p_rdata <= q_head;
                4'd4:  p_rdata <= q_tail;
                4'd5:  p_rdata <= {q_head[15:0], 8'd0, err_code, 2'd0, err, (state != S_IDLE)};
                4'd6:  p_rdata <= timeout;
                4'd7:  p_rdata <= last_fence;
                4'd8:  p_rdata <= kcycles;
                4'd10: p_rdata <= launches;
                4'd11: p_rdata <= loads;
                default: p_rdata <= 32'd0;
            endcase
        end
    end

    // ---------------------------------------------------------------- engine
    always @(posedge clk) begin
        irq_fence <= 1'b0;
        dcr_we    <= 1'b0;
        pw_en     <= 1'b0;
        if (reset) begin
            state        <= S_IDLE;
            waiting      <= 1'b0;
            m_req        <= 1'b0;
            enable       <= 1'b0;
            err          <= 1'b0;
            err_code     <= 4'd0;
            q_base       <= 32'd0;
            q_size       <= 32'd1;
            q_head       <= 32'd0;
            q_tail       <= 32'd0;
            timeout      <= 32'd0;
            last_fence   <= 32'd0;
            kcycles      <= 32'd0;
            launches     <= 32'd0;
            loads        <= 32'd0;
            loaded_valid <= 1'b0;
            gpu_start    <= 1'b0;
        end else begin
            // register writes
            if (p_req & p_we) begin
                case (p_addr[5:2])
                    4'd0: enable  <= p_wdata[0];
                    4'd1: q_base  <= p_wdata;
                    4'd2: q_size  <= p_wdata;
                    4'd4: q_tail  <= p_wdata;
                    4'd6: timeout <= p_wdata;
                    4'd9: if (state == S_ERR) begin       // ERR_CLR: skip the failing descriptor
                        err    <= 1'b0;
                        q_head <= q_head + 32'd1;
                        state  <= S_IDLE;
                    end
                    default: ;
                endcase
            end

            case (state)
                S_IDLE: if (enable && q_head != q_tail) begin
                    fi      <= 3'd0;
                    m_req   <= 1'b1;
                    m_we    <= 1'b0;
                    m_addr  <= slot;
                    waiting <= 1'b0;
                    state   <= S_FETCH;
                end

                // ---- read the 8 descriptor words ----
                S_FETCH: begin
                    if (!waiting) begin
                        if (m_gnt) begin m_req <= 1'b0; waiting <= 1'b1; end
                    end else if (m_rvalid) begin
                        waiting <= 1'b0;
                        if (m_err) begin
                            err_code <= 4'd3; state <= S_ERR;
                        end else begin
                            d[fi] <= m_rdata;
                            if (fi == 3'd7) state <= S_CHECK;
                            else begin
                                fi     <= fi + 3'd1;
                                m_addr <= m_addr + 32'd4;
                                m_req  <= 1'b1;
                            end
                        end
                    end
                end

                S_CHECK: begin
                    if (d[1] == 32'd0 || d[1] > 32'd256 || d[2] == 32'd0 || d[2] > 32'd255) begin
                        err_code <= 4'd1; state <= S_ERR;
                    end else if (!loaded_valid || loaded_addr != d[0] || d[7][1]) begin
                        li      <= 9'd0;
                        m_req   <= 1'b1;
                        m_we    <= 1'b0;
                        m_addr  <= d[0];
                        waiting <= 1'b0;
                        loaded_valid <= 1'b0;
                        state   <= S_LOAD;
                    end else begin
                        state <= S_GRST;
                    end
                end

                // ---- stream the kernel into the program RAM (GPU held in reset) ----
                S_LOAD: begin
                    if (!waiting) begin
                        if (m_gnt) begin m_req <= 1'b0; waiting <= 1'b1; end
                    end else if (m_rvalid) begin
                        waiting <= 1'b0;
                        if (m_err) begin
                            err_code <= 4'd3; state <= S_ERR;
                        end else begin
                            pw_en   <= 1'b1;
                            pw_addr <= li[7:0];
                            pw_data <= m_rdata[15:0];
                            if (li + 9'd1 == d[1][8:0] || (li == 9'd255)) begin
                                loaded_addr  <= d[0];
                                loaded_valid <= 1'b1;
                                loads        <= loads + 32'd1;
                                state        <= S_GRST;
                            end else begin
                                li     <= li + 9'd1;
                                m_addr <= m_addr + 32'd4;
                                m_req  <= 1'b1;
                            end
                        end
                    end
                end

                // ---- one cycle of GPU reset (gpu_reset is high here), then DCR, start ----
                S_GRST: begin
                    kcycles <= 32'd0;
                    state   <= S_DCR;
                end
                // tiny-gpu's dispatcher reads the thread count combinationally,
                // so the DCR must be written one cycle before start rises
                S_DCR: begin
                    dcr_we <= 1'b1;
                    state  <= S_START;
                end
                S_START: begin
                    gpu_start <= 1'b1;
                    state     <= S_RUN;
                end

                S_RUN: begin
                    kcycles <= kcycles + 32'd1;
                    if (gpu_done && !gpu_outstanding) begin
                        gpu_start <= 1'b0;
                        if (gpu_bus_err) begin
                            err_code <= 4'd4; state <= S_ERR;
                        end else begin
                            m_req   <= 1'b1;
                            m_we    <= 1'b1;
                            m_addr  <= d[5];
                            m_wdata <= d[6];
                            waiting <= 1'b0;
                            state   <= S_FENCE;
                        end
                    end else if (timeout != 32'd0 && kcycles >= timeout) begin
                        gpu_start <= 1'b0;
                        err_code  <= 4'd2;
                        state     <= S_ERR;
                    end
                end

                // ---- fence: only after every GPU store was acknowledged ----
                S_FENCE: begin
                    if (!waiting) begin
                        if (m_gnt) begin m_req <= 1'b0; waiting <= 1'b1; end
                    end else if (m_rvalid) begin
                        waiting <= 1'b0;
                        if (m_err) begin
                            err_code <= 4'd3; state <= S_ERR;
                        end else state <= S_DONE;
                    end
                end

                S_DONE: begin
                    q_head     <= q_head + 32'd1;
                    last_fence <= d[6];
                    launches   <= launches + 32'd1;
                    irq_fence  <= d[7][0];
                    state      <= S_IDLE;
                end

                S_ERR: begin
                    if (!err_clr) err <= 1'b1;
                    m_req <= 1'b0;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
