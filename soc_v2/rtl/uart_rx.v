`timescale 1ns / 1ps
// 8N1 UART receiver. `valid` pulses for one cycle with the received byte.
module uart_rx #(
    parameter CLKS_PER_BIT = 434
) (
    input            clk,
    input            reset,
    input            rx,
    output reg       valid,
    output reg [7:0] data
);
    localparam IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;

    // two-flop synchronizer: rx comes from an asynchronous pin
    reg rx_meta, rx_s;
    always @(posedge clk) begin
        rx_meta <= reset ? 1'b1 : rx;
        rx_s    <= reset ? 1'b1 : rx_meta;
    end

    reg [1:0] state;
    reg [$clog2(CLKS_PER_BIT)-1:0] clk_cnt;
    reg [2:0] bit_idx;

    always @(posedge clk) begin
        valid <= 1'b0;
        if (reset) begin
            state   <= IDLE;
            clk_cnt <= 0;
            bit_idx <= 0;
        end else begin
            case (state)
                IDLE:
                    if (!rx_s) begin
                        state   <= START;
                        clk_cnt <= 0;
                    end
                START:                               // re-check in the middle of the start bit
                    if (clk_cnt == (CLKS_PER_BIT - 1) / 2) begin
                        clk_cnt <= 0;
                        bit_idx <= 0;
                        state   <= rx_s ? IDLE : DATA;
                    end else
                        clk_cnt <= clk_cnt + 1'b1;
                DATA:                                // sample each bit in its middle
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt       <= 0;
                        data[bit_idx] <= rx_s;
                        if (bit_idx == 3'd7) state <= STOP;
                        bit_idx       <= bit_idx + 3'd1;
                    end else
                        clk_cnt <= clk_cnt + 1'b1;
                STOP:
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        state   <= IDLE;
                        valid   <= rx_s;             // drop frames with a bad stop bit
                    end else
                        clk_cnt <= clk_cnt + 1'b1;
            endcase
        end
    end
endmodule
