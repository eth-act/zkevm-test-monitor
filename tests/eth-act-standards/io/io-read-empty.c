// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/* read_input with an empty private input reports size 0 on every call. */
#include "checks.h"

int main(void) {
    const uint8_t *buf = (const uint8_t *)1;
    size_t size = 1;
    read_input(&buf, &size);
    CHECK(1, size == 0);
    size = 1;
    read_input(&buf, &size);
    CHECK(2, size == 0);
    rvtest_pass();
    return 0;
}
