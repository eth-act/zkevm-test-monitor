// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * A byte load from 0xfff, the last byte of the null pointer trap region, must
 * terminate the guest abnormally (memory-safety-guard-regions: "Any read or
 * write access to this region must trigger abnormal termination"). The
 * expected outcome is an abnormal termination with any code
 * (guard-null-lb-fff.outcome).
 */
#include "guard.h"

int main(void) {
    guard_lb(0xfff);
    rvtest_pass();
    return 0;
}
