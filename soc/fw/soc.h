// SoC memory map, drivers and interrupt helpers (see soc/rtl/soc_top.v)
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define REG32(addr) (*(volatile uint32_t *)(addr))

// ---- GPU memories ----
#define GPU_DMEM ((volatile uint8_t *)0x20000000)   // 256 x 8-bit, byte addressed
#define GPU_PMEM ((volatile uint32_t *)0x20001000)  // 256 x 16-bit, one per word

// ---- GPU control ----
#define GPU_CTRL   REG32(0x30000000)
#define GPU_DCR    REG32(0x30000004)
#define GPU_STATUS REG32(0x30000008)
#define GPU_CYCLES REG32(0x3000000C)
#define GPU_CTRL_START  (1u << 0)
#define GPU_CTRL_RESET  (1u << 1)
#define GPU_STATUS_DONE (1u << 0)
#define GPU_STATUS_BUSY (1u << 1)

// ---- system control / interrupt controller ----
#define GPIO_OUT REG32(0x40000000)
#define SYS_EXIT REG32(0x40000004)
#define IRQ_EN   REG32(0x40000008)
#define IRQ_PEND REG32(0x4000000C)
#define GPIO_IN  REG32(0x40000010)
#define IRQ_GPU     (1u << 0)   // GPU kernel done (write 1 to IRQ_PEND to clear)
#define IRQ_UART_RX (1u << 1)   // UART byte received (cleared by reading UART_DATA)

// ---- UART ----
#define UART_DATA   REG32(0x40001000)
#define UART_STATUS REG32(0x40001004)

// ---- CPU interrupt enable (machine mode) ----
static inline void irq_set_handler(void (*handler)(void)) {
    __asm__ volatile("csrw mtvec, %0" ::"r"(handler));
}
static inline void irq_global_enable(void) {
    __asm__ volatile("csrs mie, %0" ::"r"(1u << 11));   // MEIE
    __asm__ volatile("csrsi mstatus, 8");               // MIE
}
static inline uint32_t rdcycle(void) {
    uint32_t c;
    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

// ---- console ----
static inline void uart_putc(char c) { UART_DATA = (uint8_t)c; }  // bus waits if TX busy

static inline void uart_puts(const char *s) {
    while (*s)
        uart_putc(*s++);
}

static inline void uart_putdec(uint32_t v) {
    char buf[10];
    int n = 0;
    do {
        buf[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    while (n)
        uart_putc(buf[--n]);
}

// ---- GPU ----
static inline void gpu_load_program(const uint16_t *prog, int n) {
    for (int i = 0; i < n; i++)
        GPU_PMEM[i] = prog[i];
}

// Reset the GPU, set the thread count and start. Completion raises IRQ_GPU.
static inline void gpu_launch(uint32_t threads) {
    GPU_CTRL = GPU_CTRL_RESET;
    GPU_CTRL = 0;
    GPU_DCR = threads;
    GPU_CTRL = GPU_CTRL_START;
}

#endif
