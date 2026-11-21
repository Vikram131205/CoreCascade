`timescale 1ns / 1ps
// ============================================================================
//  CoreCascade SoC v2: RV32IM host + tiny-gpu behind a command processor,
//  OBI crossbar, banked shared SRAM, VGA display
// ============================================================================
//  Masters (crossbar)                    Slaves (crossbar)
//   0 CPU data port (non-DTCM)            0  ITCM port B     0x0000_0000
//   1 UART boot loader                    1  DTCM port B     0x1000_0000
//   2-5 GPU data channels 0-3             2-9 SRAM banks 0-7 0x2000_0000 (bank = addr[4:2])
//   6 command processor                   10 peripherals     0x4000_0000
//   7 display (highest priority)
//
//  Peripherals (0x4000_0000 + n * 0x1000)
//   0 SYSCTL  1 UART  2 timer  3 interrupt controller  4 command processor  5 display
//
//  Interrupts: irq_ctrl source 0 CP fence, 1 CP error, 2 vsync, 3 UART RX
//              -> CPU external interrupt; timer -> CPU timer interrupt.
// ============================================================================
module soc_top #(
    parameter ITCM_WORDS = 8192,      // 32 KB
    parameter DTCM_WORDS = 4096,      // 16 KB
    parameter BANK_WORDS = 8192,      // 8 x 32 KB = 256 KB shared
    parameter UART_DIV   = 434,       // 50 MHz / 115200
    parameter GPIO_W     = 8,
    parameter FB_W       = 320,
    parameter FB_H       = 240,
    parameter H_FP = 16, H_SYNC = 96, H_BP = 48,
    parameter V_FP = 10, V_SYNC = 2,  V_BP = 33
) (
    input               clk_i,
    input               rst_ni,      // asynchronous, active low
    input               boot_i,      // strap: 1 = wait for a program over UART
    input               uart_rx_i,
    output              uart_tx_o,
    input  [GPIO_W-1:0] gpio_i,
    output [GPIO_W-1:0] gpio_o,
    output              halted_o,
    output [11:0]       vga_rgb_o,
    output              vga_hs_o,
    output              vga_vs_o
);
    localparam NM = 8, NS = 11, NP = 6, NCH = 4;
    wire clk = clk_i;

    // ---------------------------------------------------------------- reset
    wire rst;
    rst_sync u_rst (.clk(clk), .rst_ni(rst_ni), .rst_o(rst));

    // ---------------------------------------------------------------- crossbar wiring
    wire [NM-1:0]    m_req, m_we, m_gnt, m_rvalid, m_err;
    wire [NM*4-1:0]  m_be;
    wire [NM*32-1:0] m_addr, m_wdata, m_rdata;
    wire [NS-1:0]    s_req, s_we, s_gnt, s_rvalid, s_err;
    wire [NS*4-1:0]  s_be;
    wire [NS*32-1:0] s_addr, s_wdata, s_rdata;

    localparam [NS*32-1:0] SLV_BASE = {32'h4000_0000,
        32'h2000_001C, 32'h2000_0018, 32'h2000_0014, 32'h2000_0010,
        32'h2000_000C, 32'h2000_0008, 32'h2000_0004, 32'h2000_0000,
        32'h1000_0000, 32'h0000_0000};
    localparam [NS*32-1:0] SLV_MASK = {32'hF000_0000,
        {8{32'hF000_001C}},
        32'hF000_0000, 32'hF000_0000};

    obi_xbar #(.NM(NM), .NS(NS), .SLV_BASE(SLV_BASE), .SLV_MASK(SLV_MASK), .PRIO_M(7)) u_xbar (
        .clk(clk), .reset(rst),
        .m_req(m_req), .m_we(m_we), .m_be(m_be), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_gnt(m_gnt), .m_rvalid(m_rvalid), .m_rdata(m_rdata), .m_err(m_err),
        .s_req(s_req), .s_we(s_we), .s_be(s_be), .s_addr(s_addr), .s_wdata(s_wdata),
        .s_gnt(s_gnt), .s_rvalid(s_rvalid), .s_rdata(s_rdata), .s_err(s_err)
    );

    // ---------------------------------------------------------------- boot loader (M1)
    wire boot_active, boot_tx;
    uart_boot #(.CLKS_PER_BIT(UART_DIV)) u_boot (
        .clk(clk), .reset(rst), .boot_strap(boot_i), .active(boot_active),
        .rx(uart_rx_i), .tx(boot_tx),
        .req(m_req[1]), .we(m_we[1]), .be(m_be[7:4]), .addr(m_addr[63:32]), .wdata(m_wdata[63:32]),
        .gnt(m_gnt[1]), .rvalid(m_rvalid[1]), .rdata(m_rdata[63:32])
    );

    // ---------------------------------------------------------------- CPU (M0, S0, S1)
    reg boot_q;
    always @(posedge clk) boot_q <= rst | boot_active;
    wire cpu_rst = rst | boot_active | boot_q;
    wire irq_ext, mtip;

    cpu_subsys #(.ITCM_WORDS(ITCM_WORDS), .DTCM_WORDS(DTCM_WORDS)) u_cpu (
        .clk(clk), .reset(cpu_rst), .mem_reset(rst), .irq_ext(irq_ext), .irq_timer(mtip),
        .m_req(m_req[0]), .m_we(m_we[0]), .m_be(m_be[3:0]), .m_addr(m_addr[31:0]), .m_wdata(m_wdata[31:0]),
        .m_gnt(m_gnt[0]), .m_rvalid(m_rvalid[0]), .m_rdata(m_rdata[31:0]), .m_err(m_err[0]),
        .si_req(s_req[0]), .si_we(s_we[0]), .si_be(s_be[3:0]), .si_addr(s_addr[31:0]), .si_wdata(s_wdata[31:0]),
        .si_gnt(s_gnt[0]), .si_rvalid(s_rvalid[0]), .si_rdata(s_rdata[31:0]), .si_err(s_err[0]),
        .sd_req(s_req[1]), .sd_we(s_we[1]), .sd_be(s_be[7:4]), .sd_addr(s_addr[63:32]), .sd_wdata(s_wdata[63:32]),
        .sd_gnt(s_gnt[1]), .sd_rvalid(s_rvalid[1]), .sd_rdata(s_rdata[63:32]), .sd_err(s_err[1])
    );

    // ---------------------------------------------------------------- shared SRAM banks (S2-S9)
    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : bank
            obi_sram #(.WORDS(BANK_WORDS), .ROW_LSB(5)) u_bank (
                .clk(clk), .reset(rst),
                .req(s_req[2+b]), .we(s_we[2+b]), .be(s_be[(2+b)*4 +: 4]),
                .addr(s_addr[(2+b)*32 +: 32]), .wdata(s_wdata[(2+b)*32 +: 32]),
                .gnt(s_gnt[2+b]), .rvalid(s_rvalid[2+b]), .rdata(s_rdata[(2+b)*32 +: 32]), .err(s_err[2+b])
            );
        end
    endgenerate

    // ---------------------------------------------------------------- GPU (M2-M5) + command processor (M6)
    wire        gpu_rst_cp, gpu_start, gpu_done, dcr_we, pw_en, byte_mode, gpu_out, gpu_berr;
    wire [7:0]  dcr_data, pw_addr;
    wire [15:0] pw_data;
    wire [31:0] data_base;

    gpu_tiny_wrap #(.NCH(NCH)) u_gpu (
        .clk(clk), .reset(rst | gpu_rst_cp),
        .start(gpu_start), .done(gpu_done), .dcr_we(dcr_we), .dcr_data(dcr_data),
        .pw_en(pw_en), .pw_addr(pw_addr), .pw_data(pw_data),
        .data_base(data_base), .byte_mode(byte_mode),
        .outstanding(gpu_out), .bus_err(gpu_berr),
        .d_req(m_req[5:2]), .d_we(m_we[5:2]), .d_be(m_be[23:8]),
        .d_addr(m_addr[191:64]), .d_wdata(m_wdata[191:64]),
        .d_gnt(m_gnt[5:2]), .d_rvalid(m_rvalid[5:2]), .d_rdata(m_rdata[191:64]), .d_err(m_err[5:2])
    );

    // ---------------------------------------------------------------- peripherals (S10)
    wire [NP-1:0]    p_req, p_ready;
    wire             p_we;
    wire [3:0]       p_be;
    wire [11:0]      p_addr;
    wire [31:0]      p_wdata;
    wire [NP*32-1:0] p_rdata;

    periph_bridge #(.NP(NP)) u_bridge (
        .clk(clk), .reset(rst),
        .req(s_req[10]), .we(s_we[10]), .be(s_be[43:40]), .addr(s_addr[351:320]), .wdata(s_wdata[351:320]),
        .gnt(s_gnt[10]), .rvalid(s_rvalid[10]), .rdata(s_rdata[351:320]), .err(s_err[10]),
        .p_req(p_req), .p_we(p_we), .p_be(p_be), .p_addr(p_addr), .p_wdata(p_wdata),
        .p_ready(p_ready), .p_rdata(p_rdata)
    );

    wire [31:0] exit_code;
    sysctl #(.GPIO_W(GPIO_W)) u_sys (
        .clk(clk), .reset(rst),
        .p_req(p_req[0]), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata),
        .p_ready(p_ready[0]), .p_rdata(p_rdata[31:0]),
        .gpio_in(gpio_i), .gpio_out(gpio_o), .halted(halted_o), .exit_code(exit_code)
    );

    wire uart_rx_valid, periph_tx;
    uart_periph #(.CLKS_PER_BIT(UART_DIV)) u_uart (
        .clk(clk), .reset(rst), .enable(~boot_active),
        .req(p_req[1]), .we(p_we), .addr(p_addr[3:0]), .wdata(p_wdata),
        .gnt(p_ready[1]), .rdata(p_rdata[63:32]),
        .rx(uart_rx_i), .tx(periph_tx), .rx_valid(uart_rx_valid)
    );
    assign uart_tx_o = boot_active ? boot_tx : periph_tx;

    timer u_timer (
        .clk(clk), .reset(rst),
        .p_req(p_req[2]), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata),
        .p_ready(p_ready[2]), .p_rdata(p_rdata[95:64]), .mtip(mtip)
    );

    wire cp_irq_fence, cp_irq_err, vsync_irq;
    irq_ctrl #(.N(8), .EDGE_MASK(8'b0000_0111)) u_irq (
        .clk(clk), .reset(rst),
        .p_req(p_req[3]), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata),
        .p_ready(p_ready[3]), .p_rdata(p_rdata[127:96]),
        .src({4'b0000, uart_rx_valid, vsync_irq, cp_irq_err, cp_irq_fence}), .irq(irq_ext)
    );

    gpu_cp u_cp (
        .clk(clk), .reset(rst),
        .p_req(p_req[4]), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata),
        .p_ready(p_ready[4]), .p_rdata(p_rdata[159:128]),
        .m_req(m_req[6]), .m_we(m_we[6]), .m_be(m_be[27:24]), .m_addr(m_addr[223:192]), .m_wdata(m_wdata[223:192]),
        .m_gnt(m_gnt[6]), .m_rvalid(m_rvalid[6]), .m_rdata(m_rdata[223:192]), .m_err(m_err[6]),
        .gpu_reset(gpu_rst_cp), .gpu_start(gpu_start), .gpu_done(gpu_done),
        .dcr_we(dcr_we), .dcr_data(dcr_data),
        .pw_en(pw_en), .pw_addr(pw_addr), .pw_data(pw_data),
        .data_base(data_base), .byte_mode(byte_mode),
        .gpu_outstanding(gpu_out), .gpu_bus_err(gpu_berr),
        .irq_fence(cp_irq_fence), .irq_err(cp_irq_err)
    );

    display_ctrl #(.FB_W(FB_W), .FB_H(FB_H), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
                   .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP)) u_disp (
        .clk(clk), .reset(rst),
        .p_req(p_req[5]), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata),
        .p_ready(p_ready[5]), .p_rdata(p_rdata[191:160]),
        .m_req(m_req[7]), .m_we(m_we[7]), .m_be(m_be[31:28]), .m_addr(m_addr[255:224]), .m_wdata(m_wdata[255:224]),
        .m_gnt(m_gnt[7]), .m_rvalid(m_rvalid[7]), .m_rdata(m_rdata[255:224]), .m_err(m_err[7]),
        .vga_rgb(vga_rgb_o), .vga_hs(vga_hs_o), .vga_vs(vga_vs_o), .vsync_irq(vsync_irq),
        .out_active(), .out_x(), .out_y()
    );
endmodule
