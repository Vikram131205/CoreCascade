`timescale 1ns / 1ps
// 8N1 UART transmitter. Pulse `start` (while !busy) to send `data`.
module uart_tx #(
    parameter CLKS_PER_BIT = 434          // clk / baud, e.g. 50 MHz / 115200
) (
    input            clk,
    input            reset,
    input            start,
    input      [7:0] data,
    output reg       tx,
    output reg       busy
);
    reg [$clog2(CLKS_PER_BIT)-1:0] clk_cnt;
    reg [3:0] bit_idx;       // 0 = start bit, 1..8 = data, 9 = stop bit
    reg [9:0] shifter;       // {stop, data, start}, sent LSB first

    always @(posedge clk) begin
        if (reset) begin
            tx      <= 1'b1;
            busy    <= 1'b0;
            clk_cnt <= 0;
            bit_idx <= 0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                shifter <= {1'b1, data, 1'b0};
                busy    <= 1'b1;
                clk_cnt <= 0;
                bit_idx <= 0;
                tx      <= 1'b0;             // start bit goes out immediately
            end
        end else if (clk_cnt == CLKS_PER_BIT - 1) begin
            clk_cnt <= 0;
            if (bit_idx == 4'd9) begin
                busy <= 1'b0;
                tx   <= 1'b1;
            end else begin
                bit_idx <= bit_idx + 4'd1;
                tx      <= shifter[bit_idx + 4'd1];
            end
        end else begin
            clk_cnt <= clk_cnt + 1'b1;
        end
    end
endmodule
