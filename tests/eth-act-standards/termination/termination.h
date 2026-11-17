/*
 * Shared code for the termination tests.
 *
 * Each test first writes the PASS marker to public output 0, the output a passing
 * test ends with, and then ends as a failed execution. Its .outcome is fail, so it
 * passes only if the zkVM terminates abnormally. A zkVM that ignores the failure
 * finishes normally with the PASS output, and the test fails.
 */

#ifndef TERMINATION_H
#define TERMINATION_H

#include "checks.h"

static inline void write_pass_marker(void) {
    static const uint8_t pass[4] = {'P', 'A', 'S', 'S'};
    write_output(pass, sizeof pass);
}

#endif /* TERMINATION_H */
