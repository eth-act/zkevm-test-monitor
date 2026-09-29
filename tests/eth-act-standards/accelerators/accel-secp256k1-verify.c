// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicsr_zifencei
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * zkvm_secp256k1_verify: ECDSA verification on secp256k1, with valid, altered and malformed signatures and keys.
 */
#include "accel.h"
#include "vectors/zkvm_secp256k1_verify.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        bool verified = accel_verdict_init(cases[i].expect);
        zkvm_status status = zkvm_secp256k1_verify((const zkvm_secp256k1_hash *)cases[i].msg,
                                                   (const zkvm_secp256k1_signature *)cases[i].sig,
                                                   (const zkvm_secp256k1_pubkey *)cases[i].pubkey,
                                                   &verified);
        CHECK_VERDICT(i, status, verified);
    }
    rvtest_pass();
    return 0;
}
