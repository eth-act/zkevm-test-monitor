/* read_input with an empty private input reports size 0. */
#include "test_verdict.h"

int main(void) {
    const uint8_t *buf = (const uint8_t *)1;
    size_t size = 1;
    read_input(&buf, &size);
    CHECK(1, size == 0);
    test_pass();
    return 0;
}
