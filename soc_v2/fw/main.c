// CoreCascade SoC v2 firmware: exercises CPU, command processor, GPU, display,
// interrupts and exceptions. Exit code = number of failed tests.
#include "cc.h"
#include "soc.h"

// ---------------------------------------------------------------------------
// GPU kernels: written in assembly in fw/kernels/*.s and assembled by
// sw/asm/tinygpu_asm.py into build/kernels.h (one 16-bit instruction per
// 32-bit word, in the .gpu section of shared SRAM):
//   k_matadd   C[i] = A[i] + B[i];  A @ 0, B @ 8, C @ 16 (GPU addresses)
//   k_matmul   2x2 matmul;          A @ 0, B @ 4, C @ 8
//   k_pattern  pixel[i] = 3 * i     (byte mode: GPU address i = byte i)
// ---------------------------------------------------------------------------
#include "kernels.h"

// GPU data windows and the framebuffer live in shared SRAM
static volatile uint32_t win_add[24]  __attribute__((section(".shared")));
static volatile uint32_t win_mm[12]   __attribute__((section(".shared")));
static volatile uint32_t win_q[3][24] __attribute__((section(".shared")));
static volatile uint32_t win_err[24]  __attribute__((section(".shared")));
static volatile uint8_t  fb[FB_W * FB_H] __attribute__((section(".shared"), aligned(32)));

// ---------------------------------------------------------------------------
// Traps
// ---------------------------------------------------------------------------
#define TIMER_PERIOD 3000
static volatile uint32_t vsync_count, timer_ticks, rx_flag, rx_byte;
static volatile uint32_t exc_n, exc_cause[8], exc_tval[8];

__attribute__((interrupt("machine"))) static void trap_handler(void) {
    uint32_t mcause = csr_read(mcause);
    if (mcause & 0x80000000u) {
        uint32_t code = mcause & 0xFF;
        if (code == 11) {                                 // external: interrupt controller
            uint32_t pend = IRQ_PEND & IRQ_EN;
            cc_irq(pend);
            if (pend & IRQ_VSYNC) {
                vsync_count++;
                IRQ_PEND = IRQ_VSYNC;
            }
            if (pend & IRQ_UART_RX) {
                rx_byte = UART_DATA;                      // reading clears the source
                rx_flag = 1;
            }
        } else if (code == 7) {                           // machine timer
            timer_ticks++;
            uint32_t next = MTIMECMP_LO + TIMER_PERIOD;
            MTIMECMP_HI = 0xFFFFFFFFu;                    // no spurious match while updating
            if (timer_ticks < 3) {
                MTIMECMP_LO = next;
                MTIMECMP_HI = 0;
            }
        }
    } else {                                              // synchronous exception: log, skip
        exc_cause[exc_n & 7] = mcause;
        exc_tval[exc_n & 7] = csr_read(mtval);
        exc_n++;
        csr_write(mepc, csr_read(mepc) + 4);
    }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
static uint32_t lfsr = 0xACE1u;
static uint32_t rand8(void) {
    lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u);
    return lfsr & 0xFF;
}

static int report(const char *name, int ok) {
    uart_puts(name);
    uart_puts(ok ? ": PASS" : ": FAIL");
    return ok ? 0 : 1;
}

static void fill_matadd(volatile uint32_t *w) {
    for (int i = 0; i < 8; i++) {
        w[i] = rand8();
        w[8 + i] = rand8();
        w[16 + i] = 0;
    }
}

static int check_matadd(volatile uint32_t *w) {
    for (int i = 0; i < 8; i++)
        if (w[16 + i] != ((w[i] + w[8 + i]) & 0xFF))
            return 0;
    return 1;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------
static const cc_kernel_t K_ADD = CC_KERNEL(k_matadd);
static const cc_kernel_t K_MM  = CC_KERNEL(k_matmul);
static const cc_kernel_t K_PAT = CC_KERNEL(k_pattern);

// 1. The CPU keeps working while the GPU runs.
static int test_concurrent(void) {
    fill_matadd(win_add);
    uint32_t f = cc_launch(&K_ADD, 8, win_add, 0);
    uint32_t spins = 0, acc = 0;
    while (!cc_done(f)) {                                 // useful CPU work meanwhile
        acc = acc * 31u + spins;
        spins++;
    }
    int ok = check_matadd(win_add) && spins > 0;
    int r = report("matadd while CPU runs", ok);
    uart_puts(" (");
    uart_putdec(CP_KCYCLES);
    uart_puts(" GPU cycles, CPU looped ");
    uart_putdec(spins);
    uart_puts(" times)\n");
    GPIO_OUT = acc;
    return r;
}

// 2. matmul; the expected values use the hardware multiplier.
static int test_matmul(void) {
    uint32_t a[4], b[4];
    for (int i = 0; i < 4; i++) {
        a[i] = rand8() & 0x0F;
        b[i] = rand8() & 0x07;
        win_mm[i] = a[i];
        win_mm[4 + i] = b[i];
        win_mm[8 + i] = 0;
    }
    cc_wait(cc_launch(&K_MM, 4, win_mm, 0));
    int ok = 1;
    for (int r = 0; r < 2; r++)
        for (int c = 0; c < 2; c++)
            if (win_mm[8 + 2 * r + c] != ((a[2 * r] * b[c] + a[2 * r + 1] * b[2 + c]) & 0xFF))
                ok = 0;
    int ret = report("matmul 2x2", ok);
    uart_puts(" (");
    uart_putdec(CP_KCYCLES);
    uart_puts(" GPU cycles)\n");
    return ret;
}

// 3. Three launches queued back to back; the kernel is loaded only once.
static int test_queue(void) {
    uint32_t loads0 = CP_LOADS;
    uint32_t f = 0;
    for (int q = 0; q < 3; q++) {
        fill_matadd(win_q[q]);
        f = cc_launch(&K_ADD, 8, win_q[q], 0);
    }
    cc_wait(f);
    int ok = check_matadd(win_q[0]) && check_matadd(win_q[1]) && check_matadd(win_q[2]);
    uint32_t loads = CP_LOADS - loads0;
    ok = ok && loads == 1;
    int r = report("3 queued launches", ok);
    uart_puts(" (kernel loads: ");
    uart_putdec(loads);
    uart_puts(")\n");
    return r;
}

// 4. The GPU renders a framebuffer; the display scans it out (no copy).
static int test_display(void) {
    const uint32_t n = FB_W * FB_H;
    uint32_t f = 0;
    for (uint32_t i = 0; i < n; i += 128)
        f = cc_launch(&K_PAT, (n - i < 128) ? n - i : 128, &fb[i], CC_BYTE);
    cc_wait(f);
    int ok = 1;
    for (uint32_t i = 0; i < n; i++)
        if (fb[i] != (((i & 127) * 3) & 0xFF))
            ok = 0;
    DISP_FB_BASE = (uint32_t)fb;
    IRQ_EN |= IRQ_VSYNC;
    DISP_CTRL = 1;
    uart_puts("display: scanning out\n");
    for (uint32_t t = 0; t < 2000000 && vsync_count < 3; t++)
        ;
    ok = ok && vsync_count >= 3 && DISP_FB_CUR == (uint32_t)fb;
    int r = report("GPU -> framebuffer -> display", ok);
    uart_puts(" (");
    uart_putdec(vsync_count);
    uart_puts(" vsync interrupts)\n");
    return r;
}

// 5. A bad launch raises a command-processor error; the queue recovers.
static int test_cp_error(void) {
    uint32_t f = cc_launch(&K_ADD, 0, win_err, 0);        // 0 threads: invalid
    int r1 = cc_wait(f);
    uint32_t code = cc_error;
    cc_clear_error();
    fill_matadd(win_err);
    int r2 = cc_wait(cc_launch(&K_ADD, 8, win_err, 0));
    int ok = r1 == -1 && code == 1 && r2 == 0 && check_matadd(win_err);
    int r = report("command-processor error + recovery", ok);
    uart_puts(" (error code ");
    uart_putdec(code);
    uart_puts(")\n");
    return r;
}

// 6. Precise exceptions: ecall, illegal, misaligned load, load + store access fault.
static int test_exceptions(void) {
    static volatile uint32_t word;
    uint32_t base = (uint32_t)&word;
    exc_n = 0;
    __asm__ volatile("ecall");
    __asm__ volatile(".word 0x00000000");                 // illegal instruction
    (void)*(volatile uint32_t *)(base + 1);               // misaligned load
    (void)*(volatile uint32_t *)0x50000000;               // unmapped: crossbar error
    *(volatile uint32_t *)0x50000004 = 1;                 // unmapped store
    static const uint32_t want[5] = {11, 2, 4, 5, 7};
    int ok = exc_n == 5;
    for (int i = 0; i < 5 && ok; i++)
        if (exc_cause[i] != want[i])
            ok = 0;
    ok = ok && exc_tval[2] == base + 1 && exc_tval[3] == 0x50000000;
    int r = report("exceptions", ok);
    uart_puts(" (causes");
    for (uint32_t i = 0; i < exc_n && i < 8; i++) {
        uart_putc(' ');
        uart_putdec(exc_cause[i]);
    }
    uart_puts(")\n");
    return r;
}

// 7. Machine timer interrupt fires three times.
static int test_timer(void) {
    timer_ticks = 0;
    MTIMECMP_HI = 0xFFFFFFFFu;
    MTIMECMP_LO = MTIME_LO + TIMER_PERIOD;
    MTIMECMP_HI = MTIME_HI;
    csr_set(mie, MIE_MTIE);
    for (uint32_t t = 0; t < 1000000 && timer_ticks < 3; t++)
        ;
    csr_clear(mie, MIE_MTIE);
    MTIMECMP_HI = 0xFFFFFFFFu;
    int r = report("timer interrupt", timer_ticks == 3);
    uart_puts(" (");
    uart_putdec(timer_ticks);
    uart_puts(" ticks)\n");
    return r;
}

int main(void) {
    csr_write(mtvec, (uint32_t)trap_handler);
    IRQ_EN = IRQ_UART_RX;
    csr_set(mie, MIE_MEIE);
    csr_set(mstatus, MSTATUS_MIE);
    cc_init();

    uart_puts("\nCoreCascade SoC v2 (chip id ");
    uart_puthex(CHIP_ID);
    uart_puts(")\n");

    int errors = 0;
    errors += test_concurrent();
    errors += test_matmul();
    errors += test_queue();
    errors += test_display();
    errors += test_cp_error();
    errors += test_exceptions();
    errors += test_timer();

    uart_puts("launches: ");
    uart_putdec(CP_LAUNCHES);
    uart_puts(", completion interrupts: ");
    uart_putdec(cc_fence_irqs);
    uart_puts("\nsend a key> ");
    while (!rx_flag)
        ;
    uart_puts("got '");
    uart_putc((char)rx_byte);
    uart_puts("'\n");

    uart_puts(errors ? "RESULT: FAIL\n" : "RESULT: PASS\n");
    return errors;
}
