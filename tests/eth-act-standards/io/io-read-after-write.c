// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * A first read_input call made late in the execution, after write_output
 * calls and stack use, returns the unchanged input: the guest writes 16
 * bytes, fills a stack buffer, then reads the input and echoes it.
 */
#include "checks.h"
#include "pattern.h"

#define PREFIX_SIZE 16
#define STACK_FILL 8192

/* Write over a large stack region, which a zkVM may share with its input. */
static void __attribute__((noinline)) fill_stack(void) {
    volatile uint8_t scratch[STACK_FILL];
    for (size_t i = 0; i < STACK_FILL; i++) {
        scratch[i] = 0xff;
    }
}

int main(void) {
    uint8_t prefix[PREFIX_SIZE];
    for (size_t i = 0; i < PREFIX_SIZE; i++) {
        prefix[i] = io_pattern(i);
    }
    write_output(prefix, 7);
    write_output(prefix + 7, PREFIX_SIZE - 7);
    fill_stack();

    const uint8_t *buf;
    size_t size;
    read_input(&buf, &size);
    write_output(buf, size);
    return 0;
}
