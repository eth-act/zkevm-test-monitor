// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The vendor memcmp wins symbol resolution against weak definitions in the
 * guest.
 *
 * The guest defines weak memcpy, memmove, memset and memcmp, as a Rust or C
 * runtime does (mem_link.h). Its memcmp is deliberately wrong. The guest
 * object comes before the vendor library in the link, so the weak memcmp wins
 * unless the library makes its strong memcmp take effect regardless of link
 * order (an always-linked runtime object or --whole-archive), as the
 * accelerated-memory-operations standard requires.
 *
 * build-guests.sh builds this guest only if the library has a strong memcmp
 * (acceleration is optional). It checks that the ELF resolves memcmp to the
 * vendor or to decoy_memcmp, never to another definition that could pass this
 * test.
 */
#define MEM_LINK_MEMCMP
#include "mem_link.h"

/* Reports "equal" for any input. */
static int decoy_memcmp(const void *lhs, const void *rhs, size_t n) {
    (void)lhs;
    (void)rhs;
    (void)n;
    return 0;
}
int memcmp(const void *lhs, const void *rhs, size_t n) __attribute__((weak, alias("decoy_memcmp")));

static const uint8_t a[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
static const uint8_t b[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17};

int main(void) {
    /* A size the compiler cannot see keeps the call a real call. */
    volatile size_t n = 16;
    CHECK(1, memcmp(a, b, n) < 0);
    rvtest_pass();
    return 0;
}
