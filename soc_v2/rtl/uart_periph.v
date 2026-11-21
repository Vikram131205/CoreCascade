`timescale 1ns / 1ps
// ============================================================================
//  UART peripheral (CPU console), 0x4000_1000
//    +0x0 DATA    W: send byte (bus is held off while the transmitter is busy)
//                 R: {23'b0, valid, byte} - pops the receive buffer
//    +0x4 STATUS  bit0 TX_BUSY, bit1 RX_VALID, bit2 RX_OVERRUN (cleared by DATA read)
//  rx_valid is also an interrupt source (see sysctl).
// ============================================================================
module uart_periph #(
    parameter CLKS_PER_BIT = 434
) (
    input             clk,
    input             reset,
    input             enable,       // 0 while the boot loader owns the UART

    input             req,
    input             we,
    input      [3:0]  addr,
    input      [31:0] wdata,
    output            gnt,
    output reg [31:0] rdata,

    input             rx,
    output            tx,
    output reg        rx_valid
);
    wire       tx_busy;
    wire       rx_strobe;
    wire [7:0] rx_byte;
    reg  [7:0] rx_buf;
    reg        rx_overrun;

    wire is_data = (addr[3:2] == 2'd0);
    assign gnt   = !(req & we & is_data & tx_busy);   // back-pressure instead of polling
    wire   fire  = req & gnt;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .reset(reset),
        .start(fire & we & is_data), .data(wdata[7:0]),
        .tx(tx), .busy(tx_busy)
    );

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .reset(reset), .rx(rx),
        .valid(rx_strobe), .data(rx_byte)
    );

    wire pop = fire & ~we & is_data;

    always @(posedge clk) begin
        if (reset) begin
            rx_valid   <= 1'b0;
            rx_overrun <= 1'b0;
        end else begin
            if (pop) begin
                rx_valid   <= 1'b0;
                rx_overrun <= 1'b0;
            end
            if (enable & rx_strobe) begin
                rx_buf     <= rx_byte;
                rx_valid   <= 1'b1;
                rx_overrun <= rx_valid & ~pop;
            end
        end
        if (fire & ~we)
            rdata <= is_data ? {23'd0, rx_valid, rx_buf}
                             : {29'd0, rx_overrun, rx_valid, tx_busy};
    end
endmodule
