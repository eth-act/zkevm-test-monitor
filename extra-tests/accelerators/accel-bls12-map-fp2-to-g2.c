/*
 * zkvm_bls12_map_fp2_to_g2: BLS12-381 map from Fp2 to G2 (EIP-2537); a non-canonical field element must fail.
 */
#include "accel.h"
#include "vectors/zkvm_bls12_map_fp2_to_g2.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_bls12_381_g2_point out;
        et_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_bls12_map_fp2_to_g2((const zkvm_bls12_381_fp2 *)cases[i].fp, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);
    }
    et_pass();
    return 0;
}
