// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/* The public output is not capped: the guest writes 1024 bytes in one call. */
#include "checks.h"
#include "pattern.h"

#define OUTPUT_SIZE 1024

static uint8_t data[OUTPUT_SIZE];

int main(void) {
    for (size_t i = 0; i < OUTPUT_SIZE; i++) {
        data[i] = io_pattern(i);
    }
    write_output(data, OUTPUT_SIZE);
    return 0;
}
