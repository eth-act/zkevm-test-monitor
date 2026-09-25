/*
 * zkvm_bls12_pairing: BLS12-381 pairing check (EIP-2537); invalid, off-curve and non-subgroup points must not verify.
 */
#include "accel.h"
#include "vectors/zkvm_bls12_pairing.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        bool verified = false;
        size_t num_pairs = cases[i].pairs_len / sizeof(zkvm_bls12_381_pairing_pair);
        zkvm_status status = zkvm_bls12_pairing((const zkvm_bls12_381_pairing_pair *)cases[i].pairs, num_pairs, &verified);
        CHECK_VERDICT(i, status, verified);
    }
    test_pass();
    return 0;
}
