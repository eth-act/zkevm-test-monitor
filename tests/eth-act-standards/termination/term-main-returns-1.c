// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * main returns 1. The standard termination semantics say that a non-zero
 * return from main is an abnormal termination, and that the value is the
 * error code. _start passes the value to the termination mechanism. The
 * expected outcome is an abnormal termination with error code 1
 * (term-main-returns-1.outcome).
 *
 * Error code 1 is the most common failure code: SP1 and OpenVM also halt with
 * 1 on a failed ACT4 check, and SP1's abort() halts with 1. So this test alone
 * does not show that the value of main passes through; term-main-returns-7
 * does.
 *
 * The program does not call rvtest_pass().
 */
#include "checks.h"

int main(void) {
    return 1;
}
