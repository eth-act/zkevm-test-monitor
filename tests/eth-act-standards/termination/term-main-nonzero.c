// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * Returning a non-zero value from main is a failed termination (Termination Semantics
 * standard, "Application Entry Point Return Value"). The standard mandates only zero
 * versus non-zero, so the expected outcome is an abnormal termination with any code.
 */
#include "termination.h"

int main(void) {
    write_pass_marker();
    return 1;
}
