// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/* The public output equals the private input when the guest echoes it. */
#include "checks.h"

int main(void) {
    const uint8_t *buf;
    size_t size;
    read_input(&buf, &size);
    write_output(buf, size);
    return 0;
}
