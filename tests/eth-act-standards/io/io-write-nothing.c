// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/* Zero-length writes alone leave the public output empty. */
#include "checks.h"
#include "pattern.h"

#define DATA_SIZE 8

int main(void) {
    uint8_t data[DATA_SIZE];
    for (size_t i = 0; i < DATA_SIZE; i++) {
        data[i] = io_pattern(i);
    }
    write_output(data, 0);
    write_output(data + DATA_SIZE, 0);
    return 0;
}
