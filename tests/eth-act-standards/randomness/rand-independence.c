// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * Two executions draw different values. The guest writes 4 draws as its
 * public output, and the runner runs it twice (rand-independence.outcome:
 * distinct) and requires different outputs. A host with a fixed seed fails.
 */
#include "random.h"

#define DRAWS 4

int main(void) {
    uint64_t draws[DRAWS];
    for (int i = 0; i < DRAWS; i++) {
        draws[i] = zkvm_random_u64();
    }
    write_output((const uint8_t *)draws, sizeof draws);
    return 0;
}
