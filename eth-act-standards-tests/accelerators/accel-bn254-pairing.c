/*
 * zkvm_bn254_pairing: BN254 pairing check (EIP-197) for 0 to 10 pairs; G2 uses the EVM (imaginary, real) order.
 */
#include "accel.h"
#include "vectors/zkvm_bn254_pairing.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        bool verified = false;
        size_t num_pairs = cases[i].pairs_len / sizeof(zkvm_bn254_pairing_pair);
        zkvm_status status = zkvm_bn254_pairing((const zkvm_bn254_pairing_pair *)cases[i].pairs, num_pairs, &verified);
        CHECK_VERDICT(i, status, verified);
    }
    test_pass();
    return 0;
}
