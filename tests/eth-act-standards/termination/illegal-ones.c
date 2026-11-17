// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The all-ones instruction must not execute: it is an illegal instruction, an ACT4
 * ExceptionsSm case. ACT4's own test expects a trap into its handler; a zkVM has none,
 * so it must terminate abnormally. A zkVM that continues reaches rvtest_pass(). The
 * expected outcome is an abnormal termination.
 */
#include "termination.h"

int main(void) {
    write_pass_marker();
    __asm__ volatile(".word 0xffffffff");
    rvtest_pass();
    return 0;
}
