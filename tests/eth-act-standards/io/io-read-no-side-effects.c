// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * read_input sets its two out-parameters and changes no other guest memory,
 * and its input stays valid while the guest uses its own memory. Canary words
 * on both sides of each out-parameter, in .data and in .bss survive both
 * calls; the input survives the guest filling .bss and the stack; and a
 * second call returns the same pointer, size and bytes.
 */
#include "checks.h"
#include "pattern.h"

#define INPUT_SIZE 65541
#define CANARY 0x5ac3a55a3cc3a55aull
#define BSS_SIZE 4096
#define BSS_FILL 0xa5
#define STACK_FILL 8192

/* Out-parameters, each between two canary words on main's stack. */
struct guarded_ptr {
    uint64_t before;
    const uint8_t *value;
    uint64_t after;
};

struct guarded_size {
    uint64_t before;
    size_t value;
    uint64_t after;
};

static volatile uint64_t data_canary[4] = {CANARY, ~CANARY, CANARY, ~CANARY};
static volatile uint8_t bss_area[BSS_SIZE];

/* Canaries are written and read through volatile, so every access happens. */
static void set_canary(uint64_t *word) {
    *(volatile uint64_t *)word = CANARY;
}

static bool canary_intact(const uint64_t *word) {
    return *(const volatile uint64_t *)word == CANARY;
}

static bool out_canaries_intact(const struct guarded_ptr *ptr, const struct guarded_size *size) {
    return canary_intact(&ptr->before) && canary_intact(&ptr->after) && canary_intact(&size->before) &&
           canary_intact(&size->after);
}

static bool data_canary_intact(void) {
    return data_canary[0] == CANARY && data_canary[1] == ~CANARY && data_canary[2] == CANARY &&
           data_canary[3] == ~CANARY;
}

static bool bss_area_is(uint8_t value) {
    for (size_t i = 0; i < BSS_SIZE; i++) {
        if (bss_area[i] != value) {
            return false;
        }
    }
    return true;
}

static bool input_unchanged(const uint8_t *buf) {
    for (size_t i = 0; i < INPUT_SIZE; i++) {
        if (buf[i] != io_pattern(i)) {
            return false;
        }
    }
    return true;
}

/* Write over a large stack region below main's frame. */
static void __attribute__((noinline)) fill_stack(void) {
    volatile uint8_t scratch[STACK_FILL];
    for (size_t i = 0; i < STACK_FILL; i++) {
        scratch[i] = 0xff;
    }
}

int main(void) {
    struct guarded_ptr first_ptr;
    struct guarded_size first_size;
    set_canary(&first_ptr.before);
    set_canary(&first_ptr.after);
    set_canary(&first_size.before);
    set_canary(&first_size.after);
    read_input(&first_ptr.value, &first_size.value);
    CHECK(1, out_canaries_intact(&first_ptr, &first_size));
    CHECK(2, data_canary_intact());
    CHECK(3, bss_area_is(0));
    CHECK(4, first_size.value == INPUT_SIZE);
    CHECK(5, input_unchanged(first_ptr.value));

    for (size_t i = 0; i < BSS_SIZE; i++) {
        bss_area[i] = BSS_FILL;
    }
    fill_stack();
    CHECK(6, input_unchanged(first_ptr.value));

    struct guarded_ptr again_ptr;
    struct guarded_size again_size;
    set_canary(&again_ptr.before);
    set_canary(&again_ptr.after);
    set_canary(&again_size.before);
    set_canary(&again_size.after);
    read_input(&again_ptr.value, &again_size.value);
    CHECK(1, out_canaries_intact(&again_ptr, &again_size));
    CHECK(2, data_canary_intact());
    CHECK(3, bss_area_is(BSS_FILL));
    CHECK(7, again_ptr.value == first_ptr.value);
    CHECK(8, again_size.value == INPUT_SIZE);
    CHECK(5, input_unchanged(again_ptr.value));
    CHECK(1, out_canaries_intact(&first_ptr, &first_size));
    rvtest_pass();
    return 0;
}
