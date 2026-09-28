// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * zkvm_bn254_g1_add with a NULL result pointer should panic
 * (zkvm_accelerators.h: "If a function is called with a NULL pointer, the
 * function SHOULD panic"). The inputs are the generator, a valid point. The
 * expected outcome is an abnormal termination (accel-null-bn254-g1-add-result.outcome).
 */
#include "accel.h"

int main(void) {
    /* G1 generator (1, 2), big-endian coordinates. */
    zkvm_bn254_g1_point generator;
    test_bytes_fill(&generator, 0, sizeof generator);
    ((uint8_t *)&generator)[31] = 1;
    ((uint8_t *)&generator)[63] = 2;
    zkvm_bn254_g1_point *volatile result = NULL;
    zkvm_status status = zkvm_bn254_g1_add(&generator, &generator, result);
    NULL_CALL_RETURNED(status, "zkvm_bn254_g1_add(NULL result)");
    return 0;
}
