/*
 * Harness for act-extra guest programs.
 *
 * A self-checking test writes the 4-byte verdict "PASS" to the public output,
 * or "FAIL" followed by the little-endian u32 id of the first failing check.
 * The host compares the public output with the test's expected bytes
 * (default "PASS"), so a guest that never runs to completion also fails.
 *
 * Guests are freestanding: they include only the standard zkVM headers and
 * reach libc memory functions solely through the vendor library.
 */

#ifndef EXTRA_TEST_H
#define EXTRA_TEST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "zkvm_io.h"

static inline void et_pass(void) {
    static const uint8_t verdict[4] = {'P', 'A', 'S', 'S'};
    write_output(verdict, sizeof verdict);
}

static inline void et_fail(uint32_t id) {
    uint8_t verdict[8] = {'F', 'A', 'I', 'L',
                          (uint8_t)id, (uint8_t)(id >> 8),
                          (uint8_t)(id >> 16), (uint8_t)(id >> 24)};
    write_output(verdict, sizeof verdict);
}

/* Record the first failing check and return from main without a verdict of PASS. */
#define CHECK(id, cond)       \
    do {                      \
        if (!(cond)) {        \
            et_fail(id);      \
            return 0;         \
        }                     \
    } while (0)

/* Byte comparison that does not call the memcmp under test. */
static inline bool et_bytes_eq(const void *a, const void *b, size_t n) {
    const volatile uint8_t *x = (const volatile uint8_t *)a;
    const volatile uint8_t *y = (const volatile uint8_t *)b;
    for (size_t i = 0; i < n; i++) {
        if (x[i] != y[i]) {
            return false;
        }
    }
    return true;
}

static inline void et_bytes_fill(void *dst, uint8_t value, size_t n) {
    volatile uint8_t *d = (volatile uint8_t *)dst;
    for (size_t i = 0; i < n; i++) {
        d[i] = value;
    }
}

static inline void et_bytes_copy(void *dst, const void *src, size_t n) {
    volatile uint8_t *d = (volatile uint8_t *)dst;
    const volatile uint8_t *s = (const volatile uint8_t *)src;
    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

#endif /* EXTRA_TEST_H */
