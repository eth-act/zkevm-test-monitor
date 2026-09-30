// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * write_output takes the bytes at the time of the call: the guest writes a
 * buffer, changes it, and writes it again.
 */
#include "checks.h"
#include "pattern.h"

#define PIECE_SIZE 16

int main(void) {
    uint8_t data[PIECE_SIZE];
    for (size_t i = 0; i < PIECE_SIZE; i++) {
        data[i] = io_pattern(i);
    }
    write_output(data, PIECE_SIZE);
    for (size_t i = 0; i < PIECE_SIZE; i++) {
        data[i] = io_pattern(PIECE_SIZE + i);
    }
    write_output(data, PIECE_SIZE);
    return 0;
}
