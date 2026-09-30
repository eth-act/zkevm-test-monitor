/*
 * Checks for the eth-act standards test guests, on top of ACT4's C test runtime.
 *
 * The guests are ACT4 C tests (ACT4 >= 4.1.0): a passing test calls
 * rvtest_pass() and a failing check calls print_error() (c_test.h). Both end
 * through the zkVM's RVMODEL_HALT_PASS / RVMODEL_HALT_FAIL macros, the same
 * verdict path as the ISA tests. Those macros also write PASS or FAIL to
 * public output 0 (zkvms/<zkvm>/isa-configs/<isa>/rvmodel_macros.h), so a
 * guest that ends before rvtest_pass() has no PASS verdict. print_error()
 * also prints the failing check on zkVMs with a console.
 *
 * I/O write tests do not call rvtest_pass(): their verdict is the public
 * output, which the runner compares with the test's .expected vector, so they
 * return from main and terminate through the vendor's _start.
 *
 * Guests are freestanding: they reach libc memory functions solely through
 * the vendor library.
 */

#ifndef CHECKS_H
#define CHECKS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "c_test.h"
#include "zkvm_io.h"

/* Fail the test at check `id`. */
#define test_fail(id) print_error("check %u failed\n", (unsigned)(id))

/* Fail the test at check `id`, naming the failing case. */
#define test_fail_label(id, label) print_error("check %u failed: %s\n", (unsigned)(id), (label))

#define CHECK(id, cond)     \
    do {                    \
        if (!(cond)) {      \
            test_fail(id);  \
        }                   \
    } while (0)

#define CHECK_LABEL(id, label, cond)     \
    do {                                 \
        if (!(cond)) {                   \
            test_fail_label(id, label);  \
        }                                \
    } while (0)

/* Byte comparison that does not call the memcmp under test. */
static inline bool test_bytes_eq(const void *a, const void *b, size_t n) {
    const volatile uint8_t *x = (const volatile uint8_t *)a;
    const volatile uint8_t *y = (const volatile uint8_t *)b;
    for (size_t i = 0; i < n; i++) {
        if (x[i] != y[i]) {
            return false;
        }
    }
    return true;
}

static inline void test_bytes_fill(void *dst, uint8_t value, size_t n) {
    volatile uint8_t *d = (volatile uint8_t *)dst;
    for (size_t i = 0; i < n; i++) {
        d[i] = value;
    }
}

static inline void test_bytes_copy(void *dst, const void *src, size_t n) {
    volatile uint8_t *d = (volatile uint8_t *)dst;
    const volatile uint8_t *s = (const volatile uint8_t *)src;
    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

#endif /* CHECKS_H */
