/* Repeated read_input calls return the same pointer, size and bytes. */
#include "extra_test.h"
#include "pattern.h"

#define INPUT_SIZE 24

int main(void) {
    const uint8_t *first;
    size_t first_size;
    read_input(&first, &first_size);
    CHECK(1, first_size == INPUT_SIZE);

    for (int call = 0; call < 3; call++) {
        const uint8_t *again;
        size_t again_size;
        read_input(&again, &again_size);
        CHECK(2, again == first);
        CHECK(3, again_size == first_size);
    }
    for (size_t i = 0; i < INPUT_SIZE; i++) {
        CHECK(4, first[i] == io_pattern(i));
    }
    et_pass();
    return 0;
}
