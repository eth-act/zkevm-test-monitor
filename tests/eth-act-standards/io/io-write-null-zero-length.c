// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * write_output(NULL, 0) reads no memory, so it adds nothing to the output and
 * the program continues. NULL is not treated specially by the standard.
 */
#include "checks.h"
#include "pattern.h"

#define OUTPUT_SIZE 10

int main(void) {
    uint8_t data[OUTPUT_SIZE];
    for (size_t i = 0; i < OUTPUT_SIZE; i++) {
        data[i] = io_pattern(i);
    }
    write_output(data, 5);
    write_output(NULL, 0);
    write_output(data + 5, OUTPUT_SIZE - 5);
    return 0;
}
