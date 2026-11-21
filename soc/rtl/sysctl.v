`timescale 1ns / 1ps
// ============================================================================
//  System control + interrupt controller, 0x4000_0000
//    +0x00 GPIO_OUT  RW
//    +0x04 EXIT      W: sets the `halted` pin, value kept as exit code (R)
//    +0x08 IRQ_EN    RW  interrupt enables
//    +0x0C IRQ_PEND  R   pending sources, W1C for edge sources
//    +0x10 GPIO_IN   R
//  Sources: bit0 GPU kernel done (rising edge, W1C)
//           bit1 UART RX byte available (level, cleared by reading UART DATA)
//  irq = |(IRQ_PEND & IRQ_EN)  -> CPU machine external interrupt
// ============================================================================
module sysctl #(
    parameter GPIO_W = 8
) (
    input                   clk,
    input                   reset,

    input                   req,
    input                   we,
    input      [4:0]        addr,
    input      [31:0]       wdata,
    output reg [31:0]       rdata,

    input                   gpu_done,
    input                   uart_rx_valid,
    output                  irq,

    input      [GPIO_W-1:0] gpio_in,
    output reg [GPIO_W-1:0] gpio_out,
    output reg              halted,
    output reg [31:0]       exit_code
);
    reg [1:0] irq_en;
    reg       gpu_pend, gpu_done_q;
    wire [1:0] pend = {uart_rx_valid, gpu_pend};
    assign irq = |(pend & irq_en);

    // gpio_in is asynchronous: synchronise it
    reg [GPIO_W-1:0] gpio_meta, gpio_sync;
    always @(posedge clk) begin
        gpio_meta <= gpio_in;
        gpio_sync <= gpio_meta;
    end

    wire wr = req & we;
    always @(posedge clk) begin
        if (reset) begin
            gpio_out   <= {GPIO_W{1'b0}};
            halted     <= 1'b0;
            exit_code  <= 32'd0;
            irq_en     <= 2'b00;
            gpu_pend   <= 1'b0;
            gpu_done_q <= 1'b0;
        end else begin
            gpu_done_q <= gpu_done;
            if (wr && addr[4:2] == 3'd3 && wdata[0]) gpu_pend <= 1'b0;   // W1C
            if (gpu_done & ~gpu_done_q)              gpu_pend <= 1'b1;   // set wins
            if (wr) begin
                case (addr[4:2])
                    3'd0: gpio_out <= wdata[GPIO_W-1:0];
                    3'd1: begin
                        halted    <= 1'b1;
                        exit_code <= wdata;
                    end
                    3'd2: irq_en <= wdata[1:0];
                    default: ;
                endcase
            end
        end
        if (req & ~we) begin
            case (addr[4:2])
                3'd0:    rdata <= {{(32-GPIO_W){1'b0}}, gpio_out};
                3'd1:    rdata <= exit_code;
                3'd2:    rdata <= {30'd0, irq_en};
                3'd3:    rdata <= {30'd0, pend};
                3'd4:    rdata <= {{(32-GPIO_W){1'b0}}, gpio_sync};
                default: rdata <= 32'd0;
            endcase
        end
    end
endmodule
