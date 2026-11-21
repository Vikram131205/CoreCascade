// CoreCascade GPU runtime: asynchronous kernel launch through the command processor
#ifndef CC_H
#define CC_H

#include <stdint.h>

typedef struct {
    const uint32_t *code;      // kernel binary in shared SRAM (one 16-bit instruction per word)
    uint32_t words;
} cc_kernel_t;

#define CC_KERNEL(arr) ((cc_kernel_t){(arr), (uint32_t)(sizeof(arr) / sizeof((arr)[0]))})

// launch flags
#define CC_RELOAD (1u << 1)    // force the kernel to be reloaded into the GPU
#define CC_BYTE   (1u << 2)    // GPU address i -> data + i   (default: data + 4*i)

void     cc_init(void);
// Queue a launch and return its fence immediately; the CPU is free meanwhile.
uint32_t cc_launch(const cc_kernel_t *k, uint32_t threads, volatile void *data, uint32_t flags);
int      cc_done(uint32_t fence);                 // non-blocking check
int      cc_wait(uint32_t fence);                 // 0 = done, -1 = command-processor error
void     cc_irq(uint32_t pending);                // call from the trap handler
void     cc_clear_error(void);                    // skip the failing launch, resume the queue

extern volatile uint32_t cc_error;                // error code from the command processor
extern volatile uint32_t cc_fence_irqs;           // completion interrupts seen

#endif
