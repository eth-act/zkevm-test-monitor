// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * A byte load from and a byte store to the stack bottom, the lowest byte of
 * the stack, complete (memory-safety-guard-regions: "The guard region must be
 * contiguous and adjacent to the bottom of the stack with no gap between
 * them"). With guard-stack-lb-1 and guard-stack-sb-1, this places the guard
 * region's upper end at the stack bottom.
 */
#include "guard.h"

int main(void) {
    guard_lb(guard_stack_bottom());
    guard_sb(guard_stack_bottom());
    rvtest_pass();
    return 0;
}
