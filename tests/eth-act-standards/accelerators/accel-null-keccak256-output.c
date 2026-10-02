// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * zkvm_keccak256 with a NULL output pointer should panic (zkvm_accelerators.h:
 * "If a function is called with a NULL pointer, the function SHOULD panic").
 * The expected outcome is an abnormal termination (accel-null-keccak256-output.outcome).
 */
#include "accel.h"

int main(void) {
    static const uint8_t data[3] = {'a', 'b', 'c'};
    zkvm_keccak256_hash *volatile output = NULL;
    zkvm_status status = zkvm_keccak256(data, sizeof data, output);
    NULL_CALL_RETURNED(status, "zkvm_keccak256(NULL output)");
    return 0;
}
