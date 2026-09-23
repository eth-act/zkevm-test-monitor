/*
 * zkvm_bls12_g1_msm: BLS12-381 G1 multi-scalar multiplication (EIP-2537); points outside the subgroup must fail.
 */
#include "accel.h"
#include "vectors/zkvm_bls12_g1_msm.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_bls12_381_g1_point out;
        et_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        size_t num_pairs = cases[i].pairs_len / sizeof(zkvm_bls12_381_g1_msm_pair);
        zkvm_status status = zkvm_bls12_g1_msm((const zkvm_bls12_381_g1_msm_pair *)cases[i].pairs, num_pairs, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);
    }
    et_pass();
    return 0;
}
