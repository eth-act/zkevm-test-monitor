// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * __builtin_trap() emits the compiler's trap instruction, which C's abort paths and
 * failed checks use: ebreak with GCC, which builds these tests (LLVM, and so Rust's
 * abort and panic=abort, emit unimp, see illegal-unimp). Execution must not continue
 * past it. The expected outcome is an abnormal termination.
 */
#include "termination.h"

int main(void) {
    write_pass_marker();
    __builtin_trap();
}
