// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The vendor memcpy wins symbol resolution against weak definitions in the
 * guest.
 *
 * The guest defines weak memcpy, memmove, memset and memcmp, as a Rust or C
 * runtime does (mem_link.h). Its memcpy is deliberately wrong. The guest
 * object comes before the vendor library in the link, so the weak memcpy wins
 * unless the library makes its strong memcpy take effect regardless of link
 * order (an always-linked runtime object or --whole-archive), as the
 * accelerated-memory-operations standard requires.
 *
 * build-guests.sh builds this guest only if the library has a strong memcpy
 * (acceleration is optional). It checks that the ELF resolves memcpy to the
 * vendor or to decoy_memcpy, never to another definition that could pass this
 * test.
 */
#define MEM_LINK_MEMCPY
#include "mem_link.h"

/* Copies nothing. */
static void *decoy_memcpy(void *dest, const void *src, size_t n) {
    (void)src;
    (void)n;
    return dest;
}
void *memcpy(void *dest, const void *src, size_t n) __attribute__((weak, alias("decoy_memcpy")));

static uint8_t src[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
static uint8_t dst[16];

int main(void) {
    /* A size the compiler cannot see keeps the call a real call. */
    volatile size_t n = 16;
    memcpy(dst, src, n);
    CHECK(1, test_bytes_eq(dst, src, n));
    rvtest_pass();
    return 0;
}
