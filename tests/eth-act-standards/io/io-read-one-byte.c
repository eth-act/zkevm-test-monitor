// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/* read_input returns a one-byte private input. */
#include "checks.h"

int main(void) {
    const uint8_t *buf;
    size_t size;
    read_input(&buf, &size);
    CHECK(1, size == 1);
    CHECK(2, buf[0] == 0xa5);
    rvtest_pass();
    return 0;
}
