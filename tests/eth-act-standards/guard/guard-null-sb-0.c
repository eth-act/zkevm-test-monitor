// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * A byte store to 0x0, the first byte of the null pointer trap region, must
 * terminate the guest abnormally (memory-safety-guard-regions: "Any read or
 * write access to this region must trigger abnormal termination"). The
 * expected outcome is an abnormal termination with any code
 * (guard-null-sb-0.outcome).
 */
#include "guard.h"

int main(void) {
    guard_sb(0x0);
    rvtest_pass();
    return 0;
}
