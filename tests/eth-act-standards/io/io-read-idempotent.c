// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * Repeated read_input calls return the same pointer, size and bytes, and no
 * call changes the bytes.
 */
#include "checks.h"
#include "pattern.h"

#define INPUT_SIZE 24

/* The input must still equal io_pattern() after every call. */
static bool input_unchanged(const uint8_t *buf) {
    for (size_t i = 0; i < INPUT_SIZE; i++) {
        if (buf[i] != io_pattern(i)) {
            return false;
        }
    }
    return true;
}

int main(void) {
    const uint8_t *first;
    size_t first_size;
    read_input(&first, &first_size);
    CHECK(1, first_size == INPUT_SIZE);
    CHECK(4, input_unchanged(first));

    for (int call = 0; call < 3; call++) {
        const uint8_t *again;
        size_t again_size;
        read_input(&again, &again_size);
        CHECK(2, again == first);
        CHECK(3, again_size == first_size);
        CHECK(4, input_unchanged(again));
    }
    rvtest_pass();
    return 0;
}
