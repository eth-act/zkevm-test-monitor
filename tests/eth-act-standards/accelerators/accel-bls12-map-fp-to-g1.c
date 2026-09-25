/*
 * zkvm_bls12_map_fp_to_g1: BLS12-381 map from Fp to G1 (EIP-2537); a non-canonical field element must fail.
 */
#include "accel.h"
#include "vectors/zkvm_bls12_map_fp_to_g1.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_bls12_381_g1_point out;
        test_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_bls12_map_fp_to_g1((const zkvm_bls12_381_fp *)cases[i].fp, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);
    }
    test_pass();
    return 0;
}
