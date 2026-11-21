`timescale 1ns / 1ps
// ============================================================================
//  Machine timer (CLINT style), 0x4000_2000
//    +0x0 MTIME_LO   +0x4 MTIME_HI      free-running cycle counter (RW)
//    +0x8 MTIMECMP_LO +0xC MTIMECMP_HI  compare value (RW), resets to all ones
//  mtip = (mtime >= mtimecmp) -> CPU machine timer interrupt.
//  Write MTIMECMP_HI first (or set it to all ones) to avoid a spurious match.
// ============================================================================
module timer (
    input             clk,
    input             reset,
    input             p_req,
    input             p_we,
    input      [11:0] p_addr,
    input      [31:0] p_wdata,
    output            p_ready,
    output reg [31:0] p_rdata,
    output            mtip
);
    reg [63:0] mtime, mtimecmp;
    assign p_ready = 1'b1;
    assign mtip    = (mtime >= mtimecmp);

    always @(posedge clk) begin
        if (reset) begin
            mtime    <= 64'd0;
            mtimecmp <= {64{1'b1}};
        end else begin
            mtime <= mtime + 64'd1;
            if (p_req & p_we) begin
                case (p_addr[3:2])
                    2'd0: mtime[31:0]     <= p_wdata;
                    2'd1: mtime[63:32]    <= p_wdata;
                    2'd2: mtimecmp[31:0]  <= p_wdata;
                    2'd3: mtimecmp[63:32] <= p_wdata;
                endcase
            end
        end
        if (p_req & ~p_we) begin
            case (p_addr[3:2])
                2'd0: p_rdata <= mtime[31:0];
                2'd1: p_rdata <= mtime[63:32];
                2'd2: p_rdata <= mtimecmp[31:0];
                2'd3: p_rdata <= mtimecmp[63:32];
            endcase
        end
    end
endmodule
