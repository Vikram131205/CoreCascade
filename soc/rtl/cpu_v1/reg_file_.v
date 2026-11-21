`timescale 1ns / 1ps

module reg_file_#(parameter depth_reg = 32 ,
parameter d_width = 32)(
input clk,flush,
input [$clog2(depth_reg)-1:0] rs_addr,
input [$clog2(depth_reg)-1:0] rt_addr,
input [$clog2(depth_reg)-1:0] rd_addr,
input [d_width-1:0] write_data,
output reg [d_width-1:0] r_data_1,r_data_2,
input RegWrite
    );
     reg [d_width-1:0] mem [0 : depth_reg-1];
     wire wr_en = RegWrite && (rd_addr != 0);

     // Single-edge (posedge) write for ASIC flows. The WB->ID same-cycle case is
     // handled by the write-through bypass below instead of a negedge write.
     always @(posedge clk) begin
     if(wr_en)
     mem[rd_addr] <= write_data;
     end

     always @(*) begin
     if(flush) begin
     r_data_1 = 0;
     r_data_2 = 0;
     end
     else begin
     // x0 is hardwired to zero (no reset/init needed on the array)
     r_data_1 = (rs_addr == 0) ? 0 : (wr_en && rd_addr == rs_addr) ? write_data : mem[rs_addr];
     r_data_2 = (rt_addr == 0) ? 0 : (wr_en && rd_addr == rt_addr) ? write_data : mem[rt_addr];
     end
     end

endmodule
