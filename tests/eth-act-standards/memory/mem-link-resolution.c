// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The vendor memory functions win symbol resolution.
 *
 * This guest defines weak, deliberately wrong memcpy/memmove/memset/memcmp,
 * like the compiler-builtins definitions a Rust or C runtime brings into a
 * guest link. The accelerated-memory-operations standard requires the vendor
 * definitions to take effect regardless of link order (an always-linked runtime
 * object or --whole-archive), so each call must behave correctly. A decoy never
 * writes and always reports "equal".
 */
#include "memops.h"

__attribute__((weak)) void *memcpy(void *dest, const void *src, size_t n) {
    (void)src;
    (void)n;
    return dest;
}

__attribute__((weak)) void *memmove(void *dest, const void *src, size_t n) {
    (void)src;
    (void)n;
    return dest;
}

__attribute__((weak)) void *memset(void *dest, int c, size_t n) {
    (void)c;
    (void)n;
    return dest;
}

__attribute__((weak)) int memcmp(const void *lhs, const void *rhs, size_t n) {
    (void)lhs;
    (void)rhs;
    (void)n;
    return 0;
}

static uint8_t src[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
static uint8_t dst[16];

int main(void) {
    memcpy(dst, src, sizeof dst);
    CHECK(1, test_bytes_eq(dst, src, sizeof dst));

    memmove(dst + 1, dst, 8);
    CHECK(2, dst[1] == 1 && dst[8] == 8);

    memset(dst, 0x5a, 4);
    CHECK(3, dst[0] == 0x5a && dst[3] == 0x5a);

    CHECK(4, memcmp(src, dst, sizeof dst) != 0);

    rvtest_pass();
    return 0;
}
