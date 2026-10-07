// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * Returning a non-zero value from main is a failed termination, with that value as
 * the error code (Termination Semantics standard, "Application Entry Point Return
 * Value"). The expected outcome is an abnormal termination with code 1.
 */
#include "termination.h"

int main(void) {
    write_pass_marker();
    return 1;
}
