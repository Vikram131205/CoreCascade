`timescale 1ns / 1ps
// ============================================================================
//  CoreCascade SoC: RV32I host CPU + tiny-gpu compute unit
// ============================================================================
//
//        uart_rx ──┬──────────────────────────────┐
//                  ▼                              ▼
//            uart_boot (FSM)                 rv32i_core ◄── irq ── sysctl
//             bus master #0                  bus master #1
//             (only while boot)            imem port │ dmem port
//                  │                            │    │
//                  └──────── master mux ────────┼────┘
//                                 │             │
//                     address decoder / response mux
//      ┌─────────┬─────────┬──────┴────┬──────────┬──────────┬──────────┐
//    IMEM      DMEM     GPU mems     GPU ctrl    SYSCTL      UART
//   (CPU fetch)          (shared with tiny-gpu)  (IRQ ctl)   (console)
//
//  Memory map (addr[31:28] selects the region):
//    0x0000_0000  IMEM      4 KB CPU instructions (written by the boot loader)
//    0x1000_0000  DMEM      4 KB CPU data (.rodata/.data/.bss/stack)
//    0x2000_0000  GPU_DMEM  256 x 8-bit GPU data memory (byte addressed)
//    0x2000_1000  GPU_PMEM  256 x 16-bit GPU program memory (one per word)
//    0x3000_0000  GPU_CTRL  CTRL / DCR / STATUS / CYCLES
//    0x4000_0000  SYSCTL    GPIO_OUT / EXIT / IRQ_EN / IRQ_PEND / GPIO_IN
//    0x4000_1000  UART      DATA / STATUS
//
//  Bus protocol (every master and slave): req/we/be/addr/wdata held until
//  gnt=1; read data valid in the cycle after the grant.
// ============================================================================
module soc_top #(
    parameter IMEM_WORDS = 1024,   // 4 KB
    parameter DMEM_WORDS = 1024,   // 4 KB
    parameter UART_DIV   = 434,    // clk / baud (50 MHz / 115200)
    parameter GPIO_W     = 8
) (
    input               clk,
    input               reset,
    input               boot,       // strap: 1 = wait for a program over UART
    input               uart_rx,
    output              uart_tx,
    input  [GPIO_W-1:0] gpio_in,
    output [GPIO_W-1:0] gpio_out,
    output              halted
);
    // ------------------------------------------------------------ boot loader
    wire        boot_active;
    wire        ldr_req, ldr_we, ldr_tx;
    wire [31:0] ldr_addr, ldr_wdata;
    wire        bus_gnt;
    wire [31:0] bus_rdata;

    uart_boot #(.CLKS_PER_BIT(UART_DIV)) u_boot (
        .clk(clk), .reset(reset), .boot_strap(boot), .active(boot_active),
        .rx(uart_rx), .tx(ldr_tx),
        .req(ldr_req), .we(ldr_we), .addr(ldr_addr), .wdata(ldr_wdata),
        .gnt(bus_gnt & boot_active), .rdata(bus_rdata)
    );

    // ------------------------------------------------------------ CPU
    // one extra reset cycle after the loader lets go, so IMEM is already
    // fetching address 0 when the CPU leaves reset
    reg boot_q;
    always @(posedge clk) boot_q <= reset | boot_active;
    wire cpu_reset = reset | boot_active | boot_q;

    wire [31:0] imem_addr, imem_rdata;
    wire        cpu_req, cpu_we, cpu_irq;
    wire [3:0]  cpu_be;
    wire [31:0] cpu_addr, cpu_wdata;

    rv32i_core u_cpu (
        .clk(clk), .reset(cpu_reset), .irq(cpu_irq),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_req(cpu_req), .dmem_we(cpu_we), .dmem_be(cpu_be),
        .dmem_addr(cpu_addr), .dmem_wdata(cpu_wdata),
        .dmem_gnt(bus_gnt), .dmem_rdata(bus_rdata)
    );

    // ------------------------------------------------------------ master mux
    wire        bus_req   = boot_active ? ldr_req   : cpu_req;
    wire        bus_we    = boot_active ? ldr_we    : cpu_we;
    wire [3:0]  bus_be    = boot_active ? 4'b1111   : cpu_be;
    wire [31:0] bus_addr  = boot_active ? ldr_addr  : cpu_addr;
    wire [31:0] bus_wdata = boot_active ? ldr_wdata : cpu_wdata;

    // ------------------------------------------------------------ decoder
    localparam R_IMEM = 4'h0, R_DMEM = 4'h1, R_GPUM = 4'h2, R_GPUC = 4'h3, R_PERI = 4'h4;
    wire [3:0] region  = bus_addr[31:28];
    wire       is_uart = (region == R_PERI) &  bus_addr[12];
    wire       is_sys  = (region == R_PERI) & ~bus_addr[12];

    wire gpum_gnt, uart_gnt;
    assign bus_gnt = (region == R_GPUM) ? gpum_gnt :
                     is_uart            ? uart_gnt : 1'b1;

    // remember who answers the read, for the response mux next cycle
    localparam P_IMEM = 3'd0, P_DMEM = 3'd1, P_GPUM = 3'd2, P_GPUC = 3'd3,
               P_SYS  = 3'd4, P_UART = 3'd5, P_NONE = 3'd6;
    reg [2:0] resp_sel;
    always @(posedge clk) begin
        if (bus_req & bus_gnt)
            resp_sel <= (region == R_IMEM) ? P_IMEM :
                        (region == R_DMEM) ? P_DMEM :
                        (region == R_GPUM) ? P_GPUM :
                        (region == R_GPUC) ? P_GPUC :
                        is_sys             ? P_SYS  :
                        is_uart            ? P_UART : P_NONE;
    end

    // ------------------------------------------------------------ IMEM
    // Owned by the loader while booting, by the CPU fetch unit afterwards.
    wire imem_ldr = boot_active & bus_req & (region == R_IMEM);
    sram_sp #(.WORDS(IMEM_WORDS)) u_imem (
        .clk(clk),
        .en(boot_active ? imem_ldr : 1'b1),
        .we(imem_ldr & bus_we),
        .be(bus_be),
        .addr(boot_active ? bus_addr[$clog2(IMEM_WORDS)+1:2] : imem_addr[$clog2(IMEM_WORDS)+1:2]),
        .wdata(bus_wdata),
        .rdata(imem_rdata)
    );

    // ------------------------------------------------------------ DMEM
    wire [31:0] dmem_rdata;
    sram_sp #(.WORDS(DMEM_WORDS)) u_dmem (
        .clk(clk),
        .en(bus_req & (region == R_DMEM)),
        .we(bus_we),
        .be(bus_be),
        .addr(bus_addr[$clog2(DMEM_WORDS)+1:2]),
        .wdata(bus_wdata),
        .rdata(dmem_rdata)
    );

    // ------------------------------------------------------------ GPU
    wire [31:0] gpum_rdata, gpuc_rdata;
    wire        gpu_done;
    gpu_subsys u_gpu (
        .clk(clk), .reset(reset),
        .m_req(bus_req & (region == R_GPUM)), .m_we(bus_we), .m_be(bus_be),
        .m_addr(bus_addr[12:0]), .m_wdata(bus_wdata),
        .m_gnt(gpum_gnt), .m_rdata(gpum_rdata),
        .c_req(bus_req & (region == R_GPUC)), .c_we(bus_we),
        .c_addr(bus_addr[3:0]), .c_wdata(bus_wdata), .c_rdata(gpuc_rdata),
        .gpu_done(gpu_done)
    );

    // ------------------------------------------------------------ UART
    wire [31:0] uart_rdata;
    wire        uart_rx_valid, periph_tx;
    uart_periph #(.CLKS_PER_BIT(UART_DIV)) u_uart (
        .clk(clk), .reset(reset), .enable(~boot_active),
        .req(bus_req & is_uart), .we(bus_we), .addr(bus_addr[3:0]),
        .wdata(bus_wdata), .gnt(uart_gnt), .rdata(uart_rdata),
        .rx(uart_rx), .tx(periph_tx), .rx_valid(uart_rx_valid)
    );
    assign uart_tx = boot_active ? ldr_tx : periph_tx;

    // ------------------------------------------------------------ SYSCTL / IRQ
    wire [31:0] sys_rdata;
    sysctl #(.GPIO_W(GPIO_W)) u_sys (
        .clk(clk), .reset(reset),
        .req(bus_req & is_sys), .we(bus_we), .addr(bus_addr[4:0]),
        .wdata(bus_wdata), .rdata(sys_rdata),
        .gpu_done(gpu_done), .uart_rx_valid(uart_rx_valid), .irq(cpu_irq),
        .gpio_in(gpio_in), .gpio_out(gpio_out),
        .halted(halted), .exit_code()
    );

    // ------------------------------------------------------------ response mux
    assign bus_rdata = (resp_sel == P_IMEM) ? imem_rdata :
                       (resp_sel == P_DMEM) ? dmem_rdata :
                       (resp_sel == P_GPUM) ? gpum_rdata :
                       (resp_sel == P_GPUC) ? gpuc_rdata :
                       (resp_sel == P_SYS)  ? sys_rdata  :
                       (resp_sel == P_UART) ? uart_rdata : 32'd0;

endmodule
