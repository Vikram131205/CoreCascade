`timescale 1ns / 1ps
// ============================================================================
//  UART boot loader (hardware, no ROM needed)
// ============================================================================
//  If the `boot` strap pin is 1 at reset, the loader owns the bus and the CPU
//  is held in reset. A host PC then talks to it over the UART (8N1):
//
//    'W' addr[4] count[2] data[4*count]  -> writes count words, replies 'K'
//    'R' addr[4] count[2]                -> replies with 4*count bytes
//    'G'                                 -> replies 'K', releases the CPU
//
//  All multi-byte fields are little-endian. Addresses are bus addresses, so
//  the host can write IMEM, DMEM, GPU memories or any register.
//  If `boot` is 0 at reset, the CPU starts immediately (e.g. FPGA with
//  pre-initialised memories).
// ============================================================================
module uart_boot #(
    parameter CLKS_PER_BIT = 434
) (
    input             clk,
    input             reset,
    input             boot_strap,
    output reg        active,        // 1 = loader owns the bus, CPU in reset

    input             rx,
    output            tx,

    // bus master (same protocol as the CPU data port)
    output            req,
    output            we,
    output     [31:0] addr,
    output     [31:0] wdata,
    input             gnt,
    input      [31:0] rdata
);
    localparam S_CMD = 4'd0, S_ADDR = 4'd1, S_CNT = 4'd2, S_WDATA = 4'd3,
               S_WBUS = 4'd4, S_RBUS = 4'd5, S_RWAIT = 4'd6, S_RSEND = 4'd7,
               S_ACK = 4'd8, S_GO = 4'd9;

    wire       rx_valid;
    wire [7:0] rx_byte;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .reset(reset), .rx(rx), .valid(rx_valid), .data(rx_byte)
    );

    reg        tx_start;
    reg  [7:0] tx_byte;
    wire       tx_busy;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .reset(reset), .start(tx_start), .data(tx_byte),
        .tx(tx), .busy(tx_busy)
    );
    wire tx_ready = !tx_busy && !tx_start;

    reg [3:0]  state;
    reg [7:0]  cmd;
    reg [31:0] addr_q, word;
    reg [15:0] cnt;
    reg [1:0]  idx;
    reg        go;

    assign req   = active & ((state == S_WBUS) | (state == S_RBUS));
    assign we    = (state == S_WBUS);
    assign addr  = addr_q;
    assign wdata = word;

    wire [15:0] cnt_next = {rx_byte, cnt[15:8]};

    always @(posedge clk) begin
        tx_start <= 1'b0;
        if (reset) begin
            active <= boot_strap;
            state  <= S_CMD;
            idx    <= 2'd0;
            go     <= 1'b0;
        end else if (active) begin
            case (state)
                S_CMD: if (rx_valid) begin
                    cmd <= rx_byte;
                    idx <= 2'd0;
                    if (rx_byte == "W" || rx_byte == "R") state <= S_ADDR;
                    else if (rx_byte == "G") begin
                        go    <= 1'b1;
                        state <= S_ACK;
                    end
                end

                S_ADDR: if (rx_valid) begin
                    addr_q <= {rx_byte, addr_q[31:8]};
                    idx    <= idx + 2'd1;
                    if (idx == 2'd3) begin
                        idx   <= 2'd0;
                        state <= S_CNT;
                    end
                end

                S_CNT: if (rx_valid) begin
                    cnt <= cnt_next;
                    idx <= idx + 2'd1;
                    if (idx == 2'd1) begin
                        idx <= 2'd0;
                        if (cnt_next == 16'd0) state <= (cmd == "W") ? S_ACK : S_CMD;
                        else                   state <= (cmd == "W") ? S_WDATA : S_RBUS;
                    end
                end

                S_WDATA: if (rx_valid) begin
                    word <= {rx_byte, word[31:8]};
                    idx  <= idx + 2'd1;
                    if (idx == 2'd3) state <= S_WBUS;
                end

                S_WBUS: if (gnt) begin
                    addr_q <= addr_q + 32'd4;
                    cnt    <= cnt - 16'd1;
                    idx    <= 2'd0;
                    state  <= (cnt == 16'd1) ? S_ACK : S_WDATA;
                end

                S_RBUS:  if (gnt) state <= S_RWAIT;

                S_RWAIT: begin                 // read data valid the cycle after the grant
                    word  <= rdata;
                    idx   <= 2'd0;
                    state <= S_RSEND;
                end

                S_RSEND: if (tx_ready) begin
                    tx_byte  <= word[7:0];
                    tx_start <= 1'b1;
                    word     <= word >> 8;
                    idx      <= idx + 2'd1;
                    if (idx == 2'd3) begin
                        addr_q <= addr_q + 32'd4;
                        cnt    <= cnt - 16'd1;
                        state  <= (cnt == 16'd1) ? S_CMD : S_RBUS;
                    end
                end

                S_ACK: if (tx_ready) begin
                    tx_byte  <= "K";
                    tx_start <= 1'b1;
                    state    <= go ? S_GO : S_CMD;
                end

                S_GO: if (tx_ready) active <= 1'b0;   // wait for 'K' to leave, then run

                default: state <= S_CMD;
            endcase
        end
    end
endmodule
