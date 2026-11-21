// CPU firmware: drives tiny-gpu through the SoC bus, interrupt driven.
// Exit code (written to SYS_EXIT) = number of failures, 0 = pass.
#include "soc.h"

// ---------------------------------------------------------------------------
// Kernels (tiny-gpu 16-bit ISA, taken from tiny-gpu/test)
// ---------------------------------------------------------------------------

// C[i] = A[i] + B[i]; A @ 0, B @ 8, C @ 16
static const uint16_t matadd_kernel[] = {
    0b0101000011011110, // MUL R0, %blockIdx, %blockDim
    0b0011000000001111, // ADD R0, R0, %threadIdx
    0b1001000100000000, // CONST R1, #0      ; baseA
    0b1001001000001000, // CONST R2, #8      ; baseB
    0b1001001100010000, // CONST R3, #16     ; baseC
    0b0011010000010000, // ADD R4, R1, R0
    0b0111010001000000, // LDR R4, R4        ; A[i]
    0b0011010100100000, // ADD R5, R2, R0
    0b0111010101010000, // LDR R5, R5        ; B[i]
    0b0011011001000101, // ADD R6, R4, R5
    0b0011011100110000, // ADD R7, R3, R0
    0b1000000001110110, // STR R7, R6        ; C[i]
    0b1111000000000000, // RET
};

// 2x2 matmul; A @ 0, B @ 4, C @ 8
static const uint16_t matmul_kernel[] = {
    0b0101000011011110, // MUL R0, %blockIdx, %blockDim
    0b0011000000001111, // ADD R0, R0, %threadIdx
    0b1001000100000001, // CONST R1, #1
    0b1001001000000010, // CONST R2, #2      ; N
    0b1001001100000000, // CONST R3, #0      ; baseA
    0b1001010000000100, // CONST R4, #4      ; baseB
    0b1001010100001000, // CONST R5, #8      ; baseC
    0b0110011000000010, // DIV R6, R0, R2    ; row
    0b0101011101100010, // MUL R7, R6, R2
    0b0100011100000111, // SUB R7, R0, R7    ; col
    0b1001100000000000, // CONST R8, #0      ; acc
    0b1001100100000000, // CONST R9, #0      ; k
    0b0101101001100010, // LOOP: MUL R10, R6, R2
    0b0011101010101001, //   ADD R10, R10, R9
    0b0011101010100011, //   ADD R10, R10, R3
    0b0111101010100000, //   LDR R10, R10
    0b0101101110010010, //   MUL R11, R9, R2
    0b0011101110110111, //   ADD R11, R11, R7
    0b0011101110110100, //   ADD R11, R11, R4
    0b0111101110110000, //   LDR R11, R11
    0b0101110010101011, //   MUL R12, R10, R11
    0b0011100010001100, //   ADD R8, R8, R12
    0b0011100110010001, //   ADD R9, R9, R1
    0b0010000010010010, //   CMP R9, R2
    0b0001100000001100, //   BRn LOOP
    0b0011100101010000, // ADD R9, R5, R0
    0b1000000010011000, // STR R9, R8
    0b1111000000000000, // RET
};

#define COUNT(a) ((int)(sizeof(a) / sizeof((a)[0])))

// ---------------------------------------------------------------------------
// Interrupts
// ---------------------------------------------------------------------------
static volatile int gpu_done_flag;
static volatile int rx_flag;
static volatile uint8_t rx_byte;
static volatile uint32_t irq_count;

__attribute__((interrupt("machine"))) static void trap_handler(void) {
    uint32_t pend = IRQ_PEND & IRQ_EN;
    irq_count++;
    if (pend & IRQ_GPU) {
        IRQ_PEND = IRQ_GPU;              // acknowledge (W1C)
        gpu_done_flag = 1;
    }
    if (pend & IRQ_UART_RX) {
        rx_byte = (uint8_t)UART_DATA;    // reading DATA clears the source
        rx_flag = 1;
    }
}

// Start the kernel and sleep until the GPU-done interrupt. If `hammer` is set,
// keep reading the kernel's inputs meanwhile (contends with the GPU for its
// data memory) and count wrong values.
static int gpu_run(uint32_t threads, const uint8_t *a, const uint8_t *b, int hammer) {
    int errors = 0;
    gpu_done_flag = 0;
    gpu_launch(threads);
    while (!gpu_done_flag) {
        if (hammer)
            for (int i = 0; i < 8; i++)
                if (GPU_DMEM[i] != a[i] || GPU_DMEM[8 + i] != b[i])
                    errors++;
    }
    GPU_CTRL = 0;
    return errors;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
static uint32_t lfsr = 0xACE1u;
static uint8_t rand8(void) {
    lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u);
    return (uint8_t)lfsr;
}

static void report(const char *name, int errors) {
    uart_puts(name);
    uart_puts(errors ? ": FAIL (" : ": PASS (");
    uart_putdec(GPU_CYCLES);
    uart_puts(" GPU cycles)\n");
}

static int test_matadd(const char *name, int hammer) {
    uint8_t a[8], b[8];
    for (int i = 0; i < 8; i++) {
        a[i] = rand8();
        b[i] = rand8();
        GPU_DMEM[i] = a[i];
        GPU_DMEM[8 + i] = b[i];
        GPU_DMEM[16 + i] = 0;
    }
    gpu_load_program(matadd_kernel, COUNT(matadd_kernel));
    int errors = gpu_run(8, a, b, hammer);
    for (int i = 0; i < 8; i++)
        if (GPU_DMEM[16 + i] != (uint8_t)(a[i] + b[i]))
            errors++;
    report(name, errors);
    return errors;
}

static int test_matmul(void) {
    uint8_t a[4], b[4];
    for (int i = 0; i < 4; i++) {
        a[i] = rand8() & 0x0F;   // keep products inside 8 bits
        b[i] = rand8() & 0x07;
        GPU_DMEM[i] = a[i];
        GPU_DMEM[4 + i] = b[i];
        GPU_DMEM[8 + i] = 0;
    }
    gpu_load_program(matmul_kernel, COUNT(matmul_kernel));
    int errors = gpu_run(4, a, b, 0);
    for (int r = 0; r < 2; r++)
        for (int c = 0; c < 2; c++) {
            uint8_t expect = (uint8_t)(a[2 * r] * b[c] + a[2 * r + 1] * b[2 + c]);
            if (GPU_DMEM[8 + 2 * r + c] != expect)
                errors++;
        }
    report("matmul 2x2", errors);
    return errors;
}

int main(void) {
    irq_set_handler(trap_handler);
    IRQ_EN = IRQ_GPU | IRQ_UART_RX;
    irq_global_enable();

    uart_puts("\nCoreCascade SoC: RV32I + tiny-gpu\n");
    uint32_t t0 = rdcycle();

    int errors = 0;
    errors += test_matadd("matadd", 0);
    errors += test_matmul();
    errors += test_matadd("matadd relaunch", 0);
    errors += test_matadd("matadd + CPU reads", 1);

    uart_puts("CPU cycles: ");
    uart_putdec(rdcycle() - t0);
    uart_puts("\nsend a key> ");
    while (!rx_flag)
        ;
    uart_puts("got '");
    uart_putc((char)rx_byte);
    uart_puts("'\n");

    GPIO_OUT = (uint32_t)errors;
    uart_puts(errors ? "RESULT: FAIL\n" : "RESULT: PASS\n");
    return errors;
}
