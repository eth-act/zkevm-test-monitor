// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/* 10000 calls return: the function has no failure path. */
#include "random.h"

#define CALLS 10000

int main(void) {
    volatile uint64_t sink = 0;
    for (int i = 0; i < CALLS; i++) {
        sink ^= zkvm_random_u64();
    }
    rvtest_pass();
    return 0;
}
