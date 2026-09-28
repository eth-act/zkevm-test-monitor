// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/* Zero-length writes between non-empty writes add nothing to the output. */
#include "checks.h"
#include "pattern.h"

#define OUTPUT_SIZE 10

int main(void) {
    uint8_t data[OUTPUT_SIZE];
    for (size_t i = 0; i < OUTPUT_SIZE; i++) {
        data[i] = io_pattern(i);
    }
    write_output(data, 0);
    write_output(data, 3);
    write_output(data + 3, 0);
    write_output(data + 3, 1);
    write_output(data + 4, 0);
    write_output(data + 4, 6);
    write_output(data + OUTPUT_SIZE, 0);
    return 0;
}
