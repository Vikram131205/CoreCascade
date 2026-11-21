`timescale 1ns / 1ps
// ============================================================================
//  GPU subsystem: tiny-gpu + its program/data memories + control registers
// ============================================================================
//  Memories are single-port synchronous (SRAM-macro friendly). Each has two
//  users: the GPU (fixed priority) and the CPU bus. The CPU is granted only
//  in cycles where the GPU is not accessing that memory, so the CPU can load
//  kernels/data while the GPU is idle and simply waits if it collides with a
//  running kernel.
//
//  CPU view (offsets inside the 0x2000_0000 window, m_addr[12:0]):
//    0x0000 - 0x00FF : GPU data memory, 256 x 8-bit, one byte per address
//                      (use SB / LBU; reads return the byte on all 4 lanes)
//    0x1000 - 0x13FF : GPU program memory, 256 x 16-bit, one instruction per
//                      32-bit word (use SW / LW, upper 16 bits ignored / 0)
//
//  Control registers (0x3000_0000 window, c_addr[3:0]):
//    0x0 CTRL   RW  bit0 START (hold high while running), bit1 RESET (GPU soft reset)
//    0x4 DCR    RW  thread count for the next kernel (write pulses the GPU DCR)
//    0x8 STATUS R   bit0 DONE, bit1 BUSY
//    0xC CYCLES R   cycles spent in the last/current kernel
// ============================================================================
module gpu_subsys #(
    parameter NUM_CORES         = 2,
    parameter THREADS_PER_BLOCK = 4
) (
    input             clk,
    input             reset,

    // bus slave: GPU memories
    input             m_req,
    input             m_we,
    input      [3:0]  m_be,
    input      [12:0] m_addr,
    input      [31:0] m_wdata,
    output            m_gnt,
    output     [31:0] m_rdata,

    // bus slave: control registers (always granted, 1-cycle read latency)
    input             c_req,
    input             c_we,
    input      [3:0]  c_addr,
    input      [31:0] c_wdata,
    output reg [31:0] c_rdata,

    output            gpu_done
);
    // ------------------------------------------------------------ control
    reg        ctrl_start, ctrl_reset;
    reg [7:0]  dcr_value;
    reg        dcr_we;
    reg [31:0] cycles;
    wire       gpu_rst = reset | ctrl_reset;
    wire       busy    = ctrl_start & ~gpu_done;

    always @(posedge clk) begin
        dcr_we <= 1'b0;
        if (reset) begin
            ctrl_start <= 1'b0;
            ctrl_reset <= 1'b0;
            dcr_value  <= 8'd0;
            cycles     <= 32'd0;
        end else begin
            if (c_req & c_we) begin
                case (c_addr[3:2])
                    2'd0: begin
                        ctrl_start <= c_wdata[0];
                        ctrl_reset <= c_wdata[1];
                    end
                    2'd1: begin
                        dcr_value <= c_wdata[7:0];
                        dcr_we    <= 1'b1;
                    end
                    default: ;
                endcase
            end
            if (ctrl_reset)  cycles <= 32'd0;
            else if (busy)   cycles <= cycles + 32'd1;
        end
    end

    always @(posedge clk) begin
        if (c_req & ~c_we) begin
            case (c_addr[3:2])
                2'd0: c_rdata <= {30'd0, ctrl_reset, ctrl_start};
                2'd1: c_rdata <= {24'd0, dcr_value};
                2'd2: c_rdata <= {30'd0, busy, gpu_done};
                2'd3: c_rdata <= cycles;
            endcase
        end
    end

    // ------------------------------------------------------------ GPU core
    wire        p_valid;
    wire [7:0]  p_addr;
    reg         p_ready;
    wire [15:0] p_rdata;

    wire        d_rvalid, d_wvalid;
    wire [7:0]  d_raddr, d_waddr, d_wdata;
    reg         d_rready, d_wready;
    wire [7:0]  d_rdata;

    gpu #(
        .DATA_MEM_ADDR_BITS(8),
        .DATA_MEM_DATA_BITS(8),
        .DATA_MEM_NUM_CHANNELS(1),      // one port -> single-port SRAM
        .PROGRAM_MEM_ADDR_BITS(8),
        .PROGRAM_MEM_DATA_BITS(16),
        .PROGRAM_MEM_NUM_CHANNELS(1),
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) u_gpu (
        .clk(clk),
        .reset(gpu_rst),
        .start(ctrl_start),
        .done(gpu_done),
        .device_control_write_enable(dcr_we),
        .device_control_data(dcr_value),
        .program_mem_read_valid(p_valid),
        .program_mem_read_address(p_addr),
        .program_mem_read_ready(p_ready),
        .program_mem_read_data(p_rdata),
        .data_mem_read_valid(d_rvalid),
        .data_mem_read_address(d_raddr),
        .data_mem_read_ready(d_rready),
        .data_mem_read_data(d_rdata),
        .data_mem_write_valid(d_wvalid),
        .data_mem_write_address(d_waddr),
        .data_mem_write_data(d_wdata),
        .data_mem_write_ready(d_wready)
    );

    // tiny-gpu holds *_valid until it sees *_ready. A sync SRAM answers one
    // cycle later, so fire once and return a single-cycle ready pulse.
    wire gpu_p_fire  = p_valid  & ~p_ready;
    wire gpu_dr_fire = d_rvalid & ~d_rready;
    wire gpu_dw_fire = d_wvalid & ~d_wready & ~gpu_dr_fire;

    always @(posedge clk) begin
        if (gpu_rst) begin
            p_ready  <= 1'b0;
            d_rready <= 1'b0;
            d_wready <= 1'b0;
        end else begin
            p_ready  <= gpu_p_fire;
            d_rready <= gpu_dr_fire;
            d_wready <= gpu_dw_fire;
        end
    end

    // ------------------------------------------------------------ CPU port
    wire cpu_is_pmem = m_addr[12];
    wire cpu_p_fire  = m_req &  cpu_is_pmem & ~gpu_p_fire;
    wire cpu_d_fire  = m_req & ~cpu_is_pmem & ~(gpu_dr_fire | gpu_dw_fire);
    assign m_gnt     = cpu_is_pmem ? ~gpu_p_fire : ~(gpu_dr_fire | gpu_dw_fire);

    // ------------------------------------------------------------ program memory (256 x 16)
    reg  [15:0] pmem [0:255];
    reg  [15:0] pmem_q;
    wire [7:0]  pmem_a  = gpu_p_fire ? p_addr : m_addr[9:2];
    wire        pmem_we = cpu_p_fire & m_we & (m_be[0] | m_be[1]);

    always @(posedge clk) begin
        if (gpu_p_fire | cpu_p_fire) begin
            if (pmem_we) pmem[pmem_a] <= m_wdata[15:0];
            pmem_q <= pmem[pmem_a];
        end
    end
    assign p_rdata = pmem_q;

    // ------------------------------------------------------------ data memory (256 x 8)
    reg  [7:0] dmem [0:255];
    reg  [7:0] dmem_q;
    wire [1:0] lane     = m_addr[1:0];
    wire [7:0] cpu_byte = m_wdata >> (8 * lane);
    wire [7:0] dmem_a   = gpu_dr_fire ? d_raddr :
                          gpu_dw_fire ? d_waddr : m_addr[7:0];
    wire       dmem_en  = gpu_dr_fire | gpu_dw_fire | cpu_d_fire;
    wire       dmem_we  = gpu_dw_fire | (cpu_d_fire & m_we & m_be[lane]);
    wire [7:0] dmem_wd  = gpu_dw_fire ? d_wdata : cpu_byte;

    always @(posedge clk) begin
        if (dmem_en) begin
            if (dmem_we) dmem[dmem_a] <= dmem_wd;
            dmem_q <= dmem[dmem_a];
        end
    end
    assign d_rdata = dmem_q;

    // CPU read data: valid the cycle after its grant
    reg resp_pmem;
    always @(posedge clk) if (m_req & m_gnt) resp_pmem <= cpu_is_pmem;
    assign m_rdata = resp_pmem ? {16'd0, pmem_q} : {4{dmem_q}};

endmodule
