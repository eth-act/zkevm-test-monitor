// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * A byte store to the stack bottom - 1, the highest byte of the required
 * 4 kB stack guard region, must terminate the guest abnormally
 * (memory-safety-guard-regions: "A guard region of at least 4 kB must be
 * placed immediately below the bottom of the stack. Any read or write access
 * to this region must trigger abnormal termination"). The expected outcome is
 * an abnormal termination with any code (guard-stack-sb-1.outcome).
 */
#include "guard.h"

int main(void) {
    guard_sb(guard_stack_bottom() - 1);
    rvtest_pass();
    return 0;
}
