/* read_input returns a one-byte private input. */
#include "extra_test.h"

int main(void) {
    const uint8_t *buf;
    size_t size;
    read_input(&buf, &size);
    CHECK(1, size == 1);
    CHECK(2, buf[0] == 0xa5);
    et_pass();
    return 0;
}
