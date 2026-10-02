// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * Arm optimized-routines string/test/memcmp.c, unchanged except for LEN
 * (optimized-routines/README.md): memcmp for lengths 0..99 and then doubling up
 * to LEN, for every alignment 0..31 of both inputs, with no difference or
 * one difference of +1 or -1 at the first, middle or last byte.
 * mem-memcmp.c covers what this test does not.
 */
#include "checks.h"

#define main aor_main
#include "optimized-routines/memcmp.c"
#undef main

/* Memory for mte_mmap: the test maps at most two buffers of LEN + 2 * A bytes. */
unsigned char aor_arena[2 * (LEN + 2 * A)];
const size_t aor_arena_size = sizeof aor_arena;

int main(void) {
    if (aor_main() != 0) {
        print_error("optimized-routines memcmp test failed\n");
    }
    rvtest_pass();
    return 0;
}
