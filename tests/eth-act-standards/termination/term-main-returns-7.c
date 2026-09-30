// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * main returns 7. The standard termination semantics say that a non-zero
 * return from main is an abnormal termination, and that the value is the
 * error code. _start passes the value to the termination mechanism. The
 * expected outcome is an abnormal termination with error code 7
 * (term-main-returns-7.outcome).
 *
 * No other termination path gives error code 7, so a pass shows that _start
 * passes the value of main through to the host. The standard lets the vendor
 * define the range of error codes that the zkVM preserves; 7 fits in a
 * range of one byte.
 *
 * The program does not call rvtest_pass().
 */
#include "checks.h"

int main(void) {
    return 7;
}
