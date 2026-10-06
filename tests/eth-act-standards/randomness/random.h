/*
 * Shared by the host randomness tests (zkvm_random.h).
 *
 * build-guests.sh links a fallback zkvm_random_u64 after the vendor library
 * (include/zkvm_random_fallback.c). The linker uses it only when the vendor
 * library has none, and it calls zkvm_random_missing(), which fails the test.
 */

#ifndef RANDOM_H
#define RANDOM_H

#include "checks.h"
#include "zkvm_random.h"

void zkvm_random_missing(void) {
    print_error("the vendor library has no zkvm_random_u64\n");
}

#endif /* RANDOM_H */
