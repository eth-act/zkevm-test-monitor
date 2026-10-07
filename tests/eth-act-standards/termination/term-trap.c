// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * __builtin_trap() emits the trap instruction, unimp on RISC-V, which compilers
 * also emit for Rust's abort and panic=abort paths. Execution must not continue past
 * it. The expected outcome is an abnormal termination.
 */
#include "termination.h"

int main(void) {
    write_pass_marker();
    __builtin_trap();
}
