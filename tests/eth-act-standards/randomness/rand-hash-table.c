// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The standard's use case: a hash table keyed by host randomness. With a fixed
 * key, whoever writes the input can choose keys that all land in one bucket.
 * The table layout depends on the random key, but the result must not.
 */
#include "random.h"

#define TABLE_SIZE 32 /* power of two, larger than the key count */

/* Keys as an input author would supply them. 3 and 14 appear twice. */
static const uint64_t keys[] = {3, 14, 15, 92, 65, 35, 89, 79, 3, 23, 84, 14};
#define KEY_COUNT (sizeof keys / sizeof keys[0])
#define DISTINCT_KEYS 10

/* SplitMix64 finalizer over the keyed input. */
static uint64_t mix(uint64_t key, uint64_t seed) {
    uint64_t z = key ^ seed;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return z ^ (z >> 31);
}

int main(void) {
    const uint64_t seed = zkvm_random_u64();
    uint64_t slots[TABLE_SIZE];
    bool used[TABLE_SIZE] = {false};
    unsigned distinct = 0;

    for (unsigned i = 0; i < KEY_COUNT; i++) {
        unsigned slot = mix(keys[i], seed) & (TABLE_SIZE - 1);
        while (used[slot] && slots[slot] != keys[i]) {
            slot = (slot + 1) & (TABLE_SIZE - 1);
        }
        if (!used[slot]) {
            used[slot] = true;
            slots[slot] = keys[i];
            distinct++;
        }
    }
    CHECK(1, distinct == DISTINCT_KEYS);
    rvtest_pass();
    return 0;
}
