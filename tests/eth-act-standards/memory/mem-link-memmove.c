// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The vendor memmove wins symbol resolution against weak definitions in the
 * guest.
 *
 * The guest defines weak memcpy, memmove, memset and memcmp, as a Rust or C
 * runtime does (mem_link.h). Its memmove is deliberately wrong. The guest
 * object comes before the vendor library in the link, so the weak memmove wins
 * unless the library makes its strong memmove take effect regardless of link
 * order (an always-linked runtime object or --whole-archive), as the
 * accelerated-memory-operations standard requires.
 *
 * build-guests.sh builds this guest only if the library has a strong memmove
 * (acceleration is optional). It checks that the ELF resolves memmove to the
 * vendor or to decoy_memmove, never to another definition that could pass this
 * test.
 */
#define MEM_LINK_MEMMOVE
#include "mem_link.h"

/* Moves nothing. */
static void *decoy_memmove(void *dest, const void *src, size_t n) {
    (void)src;
    (void)n;
    return dest;
}
void *memmove(void *dest, const void *src, size_t n) __attribute__((weak, alias("decoy_memmove")));

static uint8_t buf[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};

int main(void) {
    /* A size the compiler cannot see keeps the call a real call. */
    volatile size_t n = 16;
    /* Overlapping, destination after source: buf becomes {1, 1, 2, ..., 8, 10, ...}. */
    memmove(buf + 1, buf, n - 8);
    CHECK(1, buf[1] == 1 && buf[8] == 8);
    rvtest_pass();
    return 0;
}
