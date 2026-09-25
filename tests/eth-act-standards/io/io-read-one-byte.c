/* read_input returns a one-byte private input. */
#include "test_verdict.h"

int main(void) {
    const uint8_t *buf;
    size_t size;
    read_input(&buf, &size);
    CHECK(1, size == 1);
    CHECK(2, buf[0] == 0xa5);
    test_pass();
    return 0;
}
