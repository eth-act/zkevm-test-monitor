/*
 * Helpers for the runtime guests of the eth-act standards tests.
 *
 * The runtime guests are plain C and C++ programs, not ACT4 tests. They link
 * only the vendor's static library, with the vendor's linker script unchanged
 * (build-runtime-guests.sh). Each guest checks a post-condition of the
 * vendor's _start from main. When every check holds, it writes PASS with
 * write_output, and the runner compares the public output with
 * <name>.expected. A failed check writes its reason instead. Either way the
 * guest returns 0, so the output, not the termination, gives the reason.
 * No reason starts with FAIL: the runner reads a FAIL marker as an abnormal
 * termination and does not show the output.
 */

#ifndef RT_H
#define RT_H

#include <stddef.h>
#include <stdint.h>

#include "zkvm_io.h"

/* Write a string literal, without its terminating NUL. */
#define RT_WRITE(text) write_output((const uint8_t *)(text), sizeof(text) - 1)

/* In main: when `cond` is false, write `reason` and return 0. */
#define RT_CHECK(cond, reason) \
    do {                       \
        if (!(cond)) {         \
            RT_WRITE(reason);  \
            return 0;          \
        }                      \
    } while (0)

#endif /* RT_H */
