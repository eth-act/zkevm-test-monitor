/*
 * zkvm_secp256k1_ecrecover: public-key recovery on secp256k1 for both recovery ids; invalid r or s must fail.
 */
#include "accel.h"
#include "vectors/zkvm_secp256k1_ecrecover.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_secp256k1_pubkey out;
        test_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_secp256k1_ecrecover((const zkvm_secp256k1_hash *)cases[i].msg,
                                                      (const zkvm_secp256k1_signature *)cases[i].sig,
                                                      (uint8_t)cases[i].recid, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);
    }
    test_pass();
    return 0;
}
