// CoreCascade GPU runtime (see cc.h and soc_v2/rtl/gpu_cp.v)
#include "cc.h"
#include "soc.h"

#define CC_RING 8              // ring entries (power of two)

typedef struct {
    uint32_t kernel_addr, kernel_words, threads, data_base;
    uint32_t arg_ptr, fence_addr, fence_value, flags;
} cc_desc_t;

static volatile cc_desc_t ring[CC_RING] __attribute__((section(".shared"), aligned(32)));
static volatile uint32_t fence_word __attribute__((section(".shared")));
static uint32_t next_fence;

volatile uint32_t cc_error;
volatile uint32_t cc_fence_irqs;

void cc_init(void) {
    CP_CTRL = 0;
    fence_word = 0;
    next_fence = 0;
    CP_QBASE = (uint32_t)ring;
    CP_QSIZE = CC_RING;
    CP_TIMEOUT = 2000000;      // cycles per launch before the watchdog fires
    IRQ_EN |= IRQ_CP_FENCE | IRQ_CP_ERR;
    CP_CTRL = 1;
}

uint32_t cc_launch(const cc_kernel_t *k, uint32_t threads, volatile void *data, uint32_t flags) {
    uint32_t tail = CP_QTAIL;
    while (tail - CP_QHEAD >= CC_RING)      // ring full: wait for the GPU to catch up
        ;
    volatile cc_desc_t *d = &ring[tail & (CC_RING - 1)];
    uint32_t fence = ++next_fence;
    d->kernel_addr  = (uint32_t)k->code;
    d->kernel_words = k->words;
    d->threads      = threads;
    d->data_base    = (uint32_t)data;
    d->arg_ptr      = 0;
    d->fence_addr   = (uint32_t)&fence_word;
    d->fence_value  = fence;
    d->flags        = flags | 1u;           // interrupt on completion
    // The CPU completes stores one at a time, in order, so the descriptor is in
    // memory before the command processor can see the new tail.
    CP_QTAIL = tail + 1;
    return fence;
}

int cc_done(uint32_t fence) { return (int32_t)(fence_word - fence) >= 0; }

int cc_wait(uint32_t fence) {
    while (!cc_done(fence))
        if (cc_error)
            return -1;
    return 0;
}

void cc_irq(uint32_t pending) {
    if (pending & IRQ_CP_FENCE) {
        cc_fence_irqs++;
        IRQ_PEND = IRQ_CP_FENCE;
    }
    if (pending & IRQ_CP_ERR) {
        cc_error = (CP_STATUS >> 4) & 0xF;
        IRQ_PEND = IRQ_CP_ERR;
    }
}

void cc_clear_error(void) {
    cc_error = 0;
    CP_ERR_CLR = 1;
}
