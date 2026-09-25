/*
 * zkvm_bls12_g2_msm: BLS12-381 G2 multi-scalar multiplication (EIP-2537); points outside the subgroup must fail.
 */
#include "accel.h"
#include "vectors/zkvm_bls12_g2_msm.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_bls12_381_g2_point out;
        test_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        size_t num_pairs = cases[i].pairs_len / sizeof(zkvm_bls12_381_g2_msm_pair);
        zkvm_status status = zkvm_bls12_g2_msm((const zkvm_bls12_381_g2_msm_pair *)cases[i].pairs, num_pairs, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);
    }
    test_pass();
    return 0;
}
