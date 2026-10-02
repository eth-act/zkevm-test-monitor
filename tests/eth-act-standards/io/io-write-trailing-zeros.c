// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The public output keeps the zero bytes at its end: the guest writes 13 bytes,
 * then 11 zero bytes.
 */
#include "checks.h"
#include "pattern.h"

#define DATA_SIZE 13
#define ZERO_SIZE 11

int main(void) {
    uint8_t data[DATA_SIZE];
    uint8_t zeros[ZERO_SIZE];
    for (size_t i = 0; i < DATA_SIZE; i++) {
        data[i] = io_pattern(i);
    }
    test_bytes_fill(zeros, 0, ZERO_SIZE);
    write_output(data, DATA_SIZE);
    write_output(zeros, ZERO_SIZE);
    return 0;
}
