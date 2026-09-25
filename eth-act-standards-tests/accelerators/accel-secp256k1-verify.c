/*
 * zkvm_secp256k1_verify: ECDSA verification on secp256k1, with valid, altered and malformed signatures and keys.
 */
#include "accel.h"
#include "vectors/zkvm_secp256k1_verify.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        bool verified = false;
        zkvm_status status = zkvm_secp256k1_verify((const zkvm_secp256k1_hash *)cases[i].msg,
                                                   (const zkvm_secp256k1_signature *)cases[i].sig,
                                                   (const zkvm_secp256k1_pubkey *)cases[i].pubkey,
                                                   &verified);
        CHECK_VERDICT(i, status, verified);
    }
    test_pass();
    return 0;
}
