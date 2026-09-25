/* Output written one byte per call is observed as one concatenated stream. */
#include "test_verdict.h"
#include "pattern.h"

#define OUTPUT_SIZE 64

int main(void) {
    for (size_t i = 0; i < OUTPUT_SIZE; i++) {
        uint8_t byte = io_pattern(i);
        write_output(&byte, 1);
    }
    return 0;
}
