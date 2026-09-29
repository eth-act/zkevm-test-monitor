// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * zkvm_secp256r1_verify: ECDSA verification on P-256 (EIP-7212), with valid and invalid signatures.
 */
#include "accel.h"
#include "vectors/zkvm_secp256r1_verify.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        bool verified = accel_verdict_init(cases[i].expect);
        zkvm_status status = zkvm_secp256r1_verify((const zkvm_secp256r1_hash *)cases[i].msg,
                                                   (const zkvm_secp256r1_signature *)cases[i].sig,
                                                   (const zkvm_secp256r1_pubkey *)cases[i].pubkey,
                                                   &verified);
        CHECK_VERDICT(i, status, verified);
    }
    rvtest_pass();
    return 0;
}
