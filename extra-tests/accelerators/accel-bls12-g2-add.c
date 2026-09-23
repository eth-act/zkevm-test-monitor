/*
 * zkvm_bls12_g2_add: BLS12-381 G2 addition (EIP-2537, 48-byte field elements); invalid encodings and off-curve points must fail.
 */
#include "accel.h"
#include "vectors/zkvm_bls12_g2_add.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_bls12_381_g2_point out;
        et_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_bls12_g2_add((const zkvm_bls12_381_g2_point *)cases[i].p1, (const zkvm_bls12_381_g2_point *)cases[i].p2, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);
    }
    et_pass();
    return 0;
}
