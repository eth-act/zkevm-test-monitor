// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * zkvm_sha256 with NULL data and a non-zero length should panic
 * (zkvm_accelerators.h: "If a function is called with a NULL pointer, the
 * function SHOULD panic"). The expected outcome is an abnormal termination
 * (accel-null-sha256-data.outcome).
 */
#include "accel.h"

int main(void) {
    const uint8_t *volatile data = NULL;
    zkvm_sha256_hash out;
    zkvm_status status = zkvm_sha256(data, 32, &out);
    NULL_CALL_RETURNED(status, "zkvm_sha256(NULL data, 32)");
    return 0;
}
