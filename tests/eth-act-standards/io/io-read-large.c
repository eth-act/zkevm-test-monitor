// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/* read_input returns a 64 KiB private input (plus 5 bytes). */
#include "checks.h"
#include "pattern.h"

#define INPUT_SIZE 65541

int main(void) {
    const uint8_t *buf;
    size_t size;
    read_input(&buf, &size);
    CHECK(1, size == INPUT_SIZE);
    for (size_t i = 0; i < INPUT_SIZE; i++) {
        CHECK(2, buf[i] == io_pattern(i));
    }
    rvtest_pass();
    return 0;
}
