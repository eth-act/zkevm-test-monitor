// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/* One call to zkvm_random_u64 returns. */
#include "random.h"

int main(void) {
    volatile uint64_t value = zkvm_random_u64();
    (void)value;
    rvtest_pass();
    return 0;
}
