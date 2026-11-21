// Minimal freestanding runtime. RV32I has no multiply/divide instructions, so
// the compiler calls __mulsi3/__udivsi3/__umodsi3; it may also emit
// memcpy/memset for local arrays.
#include <stddef.h>
#include <stdint.h>

uint32_t __mulsi3(uint32_t a, uint32_t b) {
    uint32_t r = 0;
    while (b) {
        if (b & 1)
            r += a;
        a <<= 1;
        b >>= 1;
    }
    return r;
}

uint32_t __udivsi3(uint32_t n, uint32_t d) {
    uint32_t q = 0, r = 0;
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) {
            r -= d;
            q |= 1u << i;
        }
    }
    return q;
}

uint32_t __umodsi3(uint32_t n, uint32_t d) {
    return n - __mulsi3(__udivsi3(n, d), d);
}

void *memset(void *dst, int c, size_t n) {
    uint8_t *d = dst;
    while (n--)
        *d++ = (uint8_t)c;
    return dst;
}

void *memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = dst;
    const uint8_t *s = src;
    while (n--)
        *d++ = *s++;
    return dst;
}
