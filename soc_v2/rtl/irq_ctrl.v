`timescale 1ns / 1ps
// ============================================================================
//  Interrupt controller, 0x4000_3000
//    +0x0 PENDING  R   pending sources; write 1 to clear an edge source
//    +0x4 ENABLE   RW  per-source enable
//  Edge sources (EDGE_MASK bit = 1) latch on a rising edge and stay pending
//  until cleared; level sources show the live input.
//  irq = |(PENDING & ENABLE) -> CPU machine external interrupt (mip.MEIP).
//  Source map (soc_top):
//    0 command processor: fence written       (edge)
//    1 command processor: error               (edge)
//    2 display: vsync                          (edge)
//    3 UART: received byte waiting             (level)
// ============================================================================
module irq_ctrl #(
    parameter N         = 8,
    parameter EDGE_MASK = 8'b0000_0111
) (
    input              clk,
    input              reset,
    input              p_req,
    input              p_we,
    input      [11:0]  p_addr,
    input      [31:0]  p_wdata,
    output             p_ready,
    output reg [31:0]  p_rdata,
    input      [N-1:0] src,
    output             irq
);
    reg  [N-1:0] latched, src_q, enable;
    wire [N-1:0] pending = (latched & EDGE_MASK) | (src & ~EDGE_MASK);
    assign irq     = |(pending & enable);
    assign p_ready = 1'b1;

    always @(posedge clk) begin
        if (reset) begin
            latched <= {N{1'b0}};
            src_q   <= {N{1'b0}};
            enable  <= {N{1'b0}};
        end else begin
            src_q <= src;
            latched <=(p_req & p_we & (p_addr[3:2] == 2'd0) ? latched & ~p_wdata[N-1:0] : latched)
                       | (src & ~src_q);                               // a new edge wins over a clear
            if (p_req & p_we & (p_addr[3:2] == 2'd1)) enable <= p_wdata[N-1:0];
        end
        if (p_req & ~p_we)
            p_rdata <= (p_addr[3:2] == 2'd0) ? {{(32-N){1'b0}}, pending} :
                       (p_addr[3:2] == 2'd1) ? {{(32-N){1'b0}}, enable}  : 32'd0;
    end
endmodule
