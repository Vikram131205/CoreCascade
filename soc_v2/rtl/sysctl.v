`timescale 1ns / 1ps
// ============================================================================
//  System control, 0x4000_0000
//    +0x00 GPIO_OUT  RW
//    +0x04 EXIT      W: sets the halted pin, value kept as exit code (R)
//    +0x08 GPIO_IN   R  (synchronised)
//    +0x0C SCRATCH   RW
//    +0x10 CHIP_ID   R  0xCC50_0002 (CoreCascade SoC v2)
//  (The interrupt controller moved to irq_ctrl.v.)
// ============================================================================
module sysctl #(
    parameter GPIO_W = 8
) (
    input                   clk,
    input                   reset,
    input                   p_req,
    input                   p_we,
    input      [11:0]       p_addr,
    input      [31:0]       p_wdata,
    output                  p_ready,
    output reg [31:0]       p_rdata,
    input      [GPIO_W-1:0] gpio_in,
    output reg [GPIO_W-1:0] gpio_out,
    output reg              halted,
    output reg [31:0]       exit_code
);
    reg [GPIO_W-1:0] gpio_meta, gpio_sync;
    reg [31:0]       scratch;
    assign p_ready = 1'b1;

    always @(posedge clk) begin
        gpio_meta <= gpio_in;
        gpio_sync <= gpio_meta;
        if (reset) begin
            gpio_out  <= {GPIO_W{1'b0}};
            halted    <= 1'b0;
            exit_code <= 32'd0;
            scratch   <= 32'd0;
        end else if (p_req & p_we) begin
            case (p_addr[4:2])
                3'd0: gpio_out <= p_wdata[GPIO_W-1:0];
                3'd1: begin
                    halted    <= 1'b1;
                    exit_code <= p_wdata;
                end
                3'd3: scratch <= p_wdata;
                default: ;
            endcase
        end
        if (p_req & ~p_we) begin
            case (p_addr[4:2])
                3'd0:    p_rdata <= {{(32-GPIO_W){1'b0}}, gpio_out};
                3'd1:    p_rdata <= exit_code;
                3'd2:    p_rdata <= {{(32-GPIO_W){1'b0}}, gpio_sync};
                3'd3:    p_rdata <= scratch;
                3'd4:    p_rdata <= 32'hCC50_0002;
                default: p_rdata <= 32'd0;
            endcase
        end
    end
endmodule
