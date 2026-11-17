// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/* 16 draws in one execution are pairwise distinct (a collision has probability about 2^-57). */
#include "random.h"

#define DRAWS 16

int main(void) {
    uint64_t draws[DRAWS];
    for (int i = 0; i < DRAWS; i++) {
        draws[i] = zkvm_random_u64();
    }
    for (int i = 0; i < DRAWS; i++) {
        for (int j = i + 1; j < DRAWS; j++) {
            CHECK(1, draws[i] != draws[j]);
        }
    }
    rvtest_pass();
    return 0;
}
