`timescale 1ns / 1ps
// Reset synchronizer: asserts immediately (asynchronously) when rst_ni goes
// low, releases on a clock edge two cycles after rst_ni goes high.
module rst_sync (
    input  clk,
    input  rst_ni,      // asynchronous, active low (pin)
    output rst_o        // synchronous release, active high (to the SoC)
);
    reg [1:0] sync;
    always @(posedge clk or negedge rst_ni) begin
        if (!rst_ni) sync <= 2'b11;
        else         sync <= {sync[0], 1'b0};
    end
    assign rst_o = sync[1];
endmodule
