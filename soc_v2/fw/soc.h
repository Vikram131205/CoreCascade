// CoreCascade SoC v2 memory map and low-level helpers (see soc_v2/rtl/soc_top.v)
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define REG32(addr) (*(volatile uint32_t *)(addr))

// ---- system control 0x4000_0000 ----
#define GPIO_OUT   REG32(0x40000000)
#define SYS_EXIT   REG32(0x40000004)
#define GPIO_IN    REG32(0x40000008)
#define SYS_SCRATCH REG32(0x4000000C)
#define CHIP_ID    REG32(0x40000010)

// ---- UART 0x4000_1000 ----
#define UART_DATA   REG32(0x40001000)   // write: send (bus waits while busy); read: pop RX
#define UART_STATUS REG32(0x40001004)

// ---- machine timer 0x4000_2000 ----
#define MTIME_LO    REG32(0x40002000)
#define MTIME_HI    REG32(0x40002004)
#define MTIMECMP_LO REG32(0x40002008)
#define MTIMECMP_HI REG32(0x4000200C)

// ---- interrupt controller 0x4000_3000 ----
#define IRQ_PEND REG32(0x40003000)      // write 1 to clear an edge source
#define IRQ_EN   REG32(0x40003004)
#define IRQ_CP_FENCE (1u << 0)
#define IRQ_CP_ERR   (1u << 1)
#define IRQ_VSYNC    (1u << 2)
#define IRQ_UART_RX  (1u << 3)

// ---- GPU command processor 0x4000_4000 ----
#define CP_CTRL       REG32(0x40004000)
#define CP_QBASE      REG32(0x40004004)
#define CP_QSIZE      REG32(0x40004008)
#define CP_QHEAD      REG32(0x4000400C)
#define CP_QTAIL      REG32(0x40004010)
#define CP_STATUS     REG32(0x40004014)
#define CP_TIMEOUT    REG32(0x40004018)
#define CP_LAST_FENCE REG32(0x4000401C)
#define CP_KCYCLES    REG32(0x40004020)
#define CP_ERR_CLR    REG32(0x40004024)
#define CP_LAUNCHES   REG32(0x40004028)
#define CP_LOADS      REG32(0x4000402C)

// ---- display 0x4000_5000 ----
#define DISP_CTRL    REG32(0x40005000)
#define DISP_FB_BASE REG32(0x40005004)
#define DISP_STATUS  REG32(0x40005008)
#define DISP_FB_CUR  REG32(0x4000500C)

// ---- CSRs ----
#define csr_read(name) ({ uint32_t v_; __asm__ volatile("csrr %0, " #name : "=r"(v_)); v_; })
#define csr_write(name, v) __asm__ volatile("csrw " #name ", %0" ::"r"(v))
#define csr_set(name, v)   __asm__ volatile("csrs " #name ", %0" ::"r"(v))
#define csr_clear(name, v) __asm__ volatile("csrc " #name ", %0" ::"r"(v))
#define MIE_MTIE (1u << 7)
#define MIE_MEIE (1u << 11)
#define MSTATUS_MIE (1u << 3)

// ---- console ----
static inline void uart_putc(char c) { UART_DATA = (uint8_t)c; }
static inline void uart_puts(const char *s) {
    while (*s)
        uart_putc(*s++);
}
static inline void uart_putdec(uint32_t v) {
    char buf[10];
    int n = 0;
    do {
        buf[n++] = (char)('0' + v % 10);      // hardware DIVU/REMU (M extension)
        v /= 10;
    } while (v);
    while (n)
        uart_putc(buf[--n]);
}
static inline void uart_puthex(uint32_t v) {
    for (int i = 28; i >= 0; i -= 4)
        uart_putc("0123456789ABCDEF"[(v >> i) & 15]);
}

#endif
