/*
 * Weak definitions for the mem-link-* guests.
 *
 * A Rust or C runtime brings weak definitions of all four functions into a
 * guest link (for Rust, compiler-builtins), and they satisfy each reference
 * before the linker reads the vendor library. Each mem-link-<fn> guest does
 * the same: it defines a weak, deliberately wrong <fn>, the decoy_<fn> alias,
 * and includes this header for correct weak definitions of the other three.
 * Define MEM_LINK_<FN> for the function under test before the include.
 */
#ifndef MEM_LINK_H
#define MEM_LINK_H

#include "memops.h"

#ifndef MEM_LINK_MEMCPY
__attribute__((weak)) void *memcpy(void *dest, const void *src, size_t n) {
    test_bytes_copy(dest, src, n);
    return dest;
}
#endif

#ifndef MEM_LINK_MEMMOVE
__attribute__((weak)) void *memmove(void *dest, const void *src, size_t n) {
    volatile uint8_t *d = (volatile uint8_t *)dest;
    const volatile uint8_t *s = (const volatile uint8_t *)src;
    if (d < s) {
        for (size_t i = 0; i < n; i++) {
            d[i] = s[i];
        }
    } else {
        for (size_t i = n; i-- > 0;) {
            d[i] = s[i];
        }
    }
    return dest;
}
#endif

#ifndef MEM_LINK_MEMSET
__attribute__((weak)) void *memset(void *dest, int c, size_t n) {
    test_bytes_fill(dest, (uint8_t)c, n);
    return dest;
}
#endif

#ifndef MEM_LINK_MEMCMP
__attribute__((weak)) int memcmp(const void *lhs, const void *rhs, size_t n) {
    const volatile uint8_t *a = (const volatile uint8_t *)lhs;
    const volatile uint8_t *b = (const volatile uint8_t *)rhs;
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i]) {
            return a[i] < b[i] ? -1 : 1;
        }
    }
    return 0;
}
#endif

#endif /* MEM_LINK_H */
