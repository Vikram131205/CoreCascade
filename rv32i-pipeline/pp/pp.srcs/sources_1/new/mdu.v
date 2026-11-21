`timescale 1ns / 1ps
// ============================================================================
//  Multiply / divide unit (RV32M), used from the EX stage
// ============================================================================
//  MUL, MULH, MULHSU, MULHU : 2 cycles in EX (operands registered, then one
//                             33x33 signed multiply -> DSP on FPGA)
//  DIV, DIVU, REM, REMU     : 1 + 32 + 1 cycles, restoring division on
//                             magnitudes, sign fixed at the end
//  RISC-V corner cases: x/0 -> quotient all ones, remainder = x;
//                       -2^31 / -1 -> quotient -2^31, remainder 0.
//  The core holds EX (freeze) while start && !done. `done` stays high until
//  the instruction leaves EX (advance) or is squashed (abort).
// ============================================================================
module mdu (
    input             clk,
    input             reset,
    input             valid,      // M instruction in EX
    input             advance,    // pipeline moves this cycle
    input             abort,      // EX instruction squashed by a trap
    input      [2:0]  funct3,
    input      [31:0] a,
    input      [31:0] b,
    output            done,
    output reg [31:0] result
);
    localparam IDLE = 2'd0, MUL = 2'd1, DIV = 2'd2, DONE = 2'd3;
    reg [1:0]  state;
    reg [2:0]  op;
    reg [31:0] ra, rb;

    // ---- multiply (2nd cycle) ----
    wire a_signed = (op == 3'b001) | (op == 3'b010);    // MULH, MULHSU
    wire b_signed = (op == 3'b001);                     // MULH
    wire signed [32:0] ma = {a_signed & ra[31], ra};
    wire signed [32:0] mb = {b_signed & rb[31], rb};
    wire signed [65:0] prod = ma * mb;

    // ---- divide ----
    wire        in_signed = ~funct3[0];                 // DIV, REM (decided at start)
    reg  [31:0] quo, rem_r, divisor;
    reg  [5:0]  count;
    reg         neg_q, neg_r, div0, ovf;
    wire [32:0] shifted = {rem_r, quo[31]};             // remainder can need 33 bits
    wire [33:0] trial   = {1'b0, shifted} - {2'b00, divisor};
    wire [31:0] abs_a = (in_signed & a[31]) ? -a : a;
    wire [31:0] abs_b = (in_signed & b[31]) ? -b : b;

    assign done = (state == DONE);

    always @(posedge clk) begin
        if (reset | abort) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE: if (valid) begin
                    op <= funct3;
                    ra <= a;
                    rb <= b;
                    if (!funct3[2]) state <= MUL;
                    else begin
                        quo     <= abs_a;
                        rem_r   <= 32'd0;
                        divisor <= abs_b;
                        count   <= 6'd32;
                        neg_q   <= in_signed & (a[31] ^ b[31]);
                        neg_r   <= in_signed & a[31];
                        div0    <= (b == 32'd0);
                        ovf     <= in_signed & (a == 32'h80000000) & (b == 32'hFFFFFFFF);
                        state   <= DIV;
                    end
                end
                MUL: begin
                    result <= (op == 3'b000) ? prod[31:0] : prod[63:32];
                    state  <= DONE;
                end
                DIV: begin
                    if (count != 6'd0) begin
                        // shift (rem:quo) left by one, subtract if it fits
                        if (!trial[33]) begin
                            rem_r <= trial[31:0];
                            quo   <= {quo[30:0], 1'b1};
                        end else begin
                            rem_r <= shifted[31:0];
                            quo   <= {quo[30:0], 1'b0};
                        end
                        count <= count - 6'd1;
                    end else begin
                        if (div0)
                            result <= op[1] ? ra : 32'hFFFFFFFF;           // REM(U) : DIV(U)
                        else if (ovf)
                            result <= op[1] ? 32'd0 : 32'h80000000;
                        else if (op[1])
                            result <= neg_r ? -rem_r : rem_r;
                        else
                            result <= neg_q ? -quo : quo;
                        state <= DONE;
                    end
                end
                DONE: if (advance) state <= IDLE;
            endcase
        end
    end
endmodule
