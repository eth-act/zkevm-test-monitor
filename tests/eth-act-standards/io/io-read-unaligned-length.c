/* read_input returns a private input whose size is not a multiple of 8. */
#include "test_verdict.h"
#include "pattern.h"

#define INPUT_SIZE 13

int main(void) {
    const uint8_t *buf;
    size_t size;
    read_input(&buf, &size);
    CHECK(1, size == INPUT_SIZE);
    for (size_t i = 0; i < INPUT_SIZE; i++) {
        CHECK(2, buf[i] == io_pattern(i));
    }
    test_pass();
    return 0;
}
