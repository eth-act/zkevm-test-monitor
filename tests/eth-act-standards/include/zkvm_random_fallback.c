/*
 * zkvm_random_u64 for a vendor library that has none. build-guests.sh links
 * this archive after the vendor library, so a vendor definition always wins.
 * This one fails the test (randomness/random.h).
 */

#include <stdint.h>

void zkvm_random_missing(void);

uint64_t zkvm_random_u64(void) {
    zkvm_random_missing();
    return 0;
}
