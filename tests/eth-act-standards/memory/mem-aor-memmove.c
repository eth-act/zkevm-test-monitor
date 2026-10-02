// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * Arm optimized-routines string/test/memmove.c, unchanged except for LEN
 * (optimized-routines/README.md): memmove for lengths 0..99 and then doubling up
 * to LEN, for every destination and source alignment 0..31, disjoint and
 * overlapping. It checks the bytes around dest and the return value.
 * mem-memmove.c covers what this test does not.
 */
#include "checks.h"

#define main aor_main
#include "optimized-routines/memmove.c"
#undef main

/* Memory for mte_mmap: the test maps at most two buffers of LEN + 2 * A bytes. */
unsigned char aor_arena[2 * (LEN + 2 * A)];
const size_t aor_arena_size = sizeof aor_arena;

int main(void) {
    if (aor_main() != 0) {
        print_error("optimized-routines memmove test failed\n");
    }
    rvtest_pass();
    return 0;
}
