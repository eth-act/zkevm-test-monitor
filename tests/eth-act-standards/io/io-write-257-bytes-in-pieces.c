// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The public output is not capped: the guest writes 257 bytes in five calls,
 * none of them longer than 64 bytes.
 */
#include "checks.h"
#include "pattern.h"

#define OUTPUT_SIZE 257
#define PIECE_SIZE 64

static uint8_t data[OUTPUT_SIZE];

int main(void) {
    for (size_t i = 0; i < OUTPUT_SIZE; i++) {
        data[i] = io_pattern(i);
    }
    for (size_t offset = 0; offset < OUTPUT_SIZE; offset += PIECE_SIZE) {
        size_t left = OUTPUT_SIZE - offset;
        write_output(data + offset, left < PIECE_SIZE ? left : PIECE_SIZE);
    }
    return 0;
}
