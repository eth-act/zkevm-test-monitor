// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * All 64 bits are random. Over 1024 draws, each bit position is both set and
 * clear, and the count of set bits is within 6 standard deviations (768) of
 * half. A correct source fails with probability below 1e-8.
 */
#include "random.h"

#define DRAWS 1024
#define HALF (DRAWS * 32)
#define SIX_SIGMA 768

static unsigned popcount64(uint64_t v) {
    unsigned n = 0;
    for (; v != 0; v &= v - 1) {
        n++;
    }
    return n;
}

int main(void) {
    uint64_t set = 0;
    uint64_t clear = 0;
    unsigned ones = 0;
    for (int i = 0; i < DRAWS; i++) {
        uint64_t value = zkvm_random_u64();
        set |= value;
        clear |= ~value;
        ones += popcount64(value);
    }
    CHECK(1, set == UINT64_MAX);
    CHECK(2, clear == UINT64_MAX);
    CHECK(3, ones >= HALF - SIX_SIGMA && ones <= HALF + SIX_SIGMA);
    rvtest_pass();
    return 0;
}
