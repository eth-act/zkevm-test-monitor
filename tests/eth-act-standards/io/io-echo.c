/* The public output equals the private input when the guest echoes it. */
#include "test_verdict.h"

int main(void) {
    const uint8_t *buf;
    size_t size;
    read_input(&buf, &size);
    write_output(buf, size);
    return 0;
}
