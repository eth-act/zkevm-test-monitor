// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The vendor memset wins symbol resolution against weak definitions in the
 * guest.
 *
 * The guest defines weak memcpy, memmove, memset and memcmp, as a Rust or C
 * runtime does (mem_link.h). Its memset is deliberately wrong. The guest
 * object comes before the vendor library in the link, so the weak memset wins
 * unless the library makes its strong memset take effect regardless of link
 * order (an always-linked runtime object or --whole-archive), as the
 * accelerated-memory-operations standard requires.
 *
 * build-guests.sh builds this guest only if the library has a strong memset
 * (acceleration is optional). It checks that the ELF resolves memset to the
 * vendor or to decoy_memset, never to another definition that could pass this
 * test.
 */
#define MEM_LINK_MEMSET
#include "mem_link.h"

/* Sets nothing. */
static void *decoy_memset(void *dest, int c, size_t n) {
    (void)c;
    (void)n;
    return dest;
}
void *memset(void *dest, int c, size_t n) __attribute__((weak, alias("decoy_memset")));

static uint8_t dst[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};

int main(void) {
    /* A size the compiler cannot see keeps the call a real call. */
    volatile size_t n = 16;
    memset(dst, 0x5a, n - 12);
    CHECK(1, dst[0] == 0x5a && dst[3] == 0x5a && dst[4] == 5);
    rvtest_pass();
    return 0;
}
