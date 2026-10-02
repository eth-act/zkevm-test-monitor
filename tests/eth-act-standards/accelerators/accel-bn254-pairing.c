// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * zkvm_bn254_pairing: BN254 pairing check (EIP-197) for 0 to 10 pairs; G2 uses the EVM (imaginary, real) order.
 */
#include "accel.h"
#include "vectors/zkvm_bn254_pairing.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        bool verified = accel_verdict_init(cases[i].expect);
        size_t num_pairs = cases[i].pairs_len / sizeof(zkvm_bn254_pairing_pair);
        zkvm_status status = zkvm_bn254_pairing((const zkvm_bn254_pairing_pair *)cases[i].pairs, num_pairs, &verified);
        CHECK_VERDICT(i, status, verified);
    }
    rvtest_pass();
    return 0;
}
