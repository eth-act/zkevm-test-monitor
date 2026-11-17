// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * abort() is a failed termination (Termination Semantics standard, "Failed
 * Termination Function"). The expected outcome is an abnormal termination.
 */
#include "termination.h"

_Noreturn void abort(void);

int main(void) {
    write_pass_marker();
    abort();
}
