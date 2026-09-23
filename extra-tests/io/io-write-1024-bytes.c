/* The public output is not capped: the guest writes 1024 bytes in one call. */
#include "extra_test.h"
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
