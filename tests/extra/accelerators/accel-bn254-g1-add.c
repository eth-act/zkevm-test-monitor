/*
 * zkvm_bn254_g1_add: BN254 G1 addition (EIP-196), including the point at infinity; off-curve points must fail.
 */
#include "accel.h"
#include "vectors/zkvm_bn254_g1_add.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_bn254_g1_point out;
        et_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_bn254_g1_add((const zkvm_bn254_g1_point *)cases[i].p1,
                                               (const zkvm_bn254_g1_point *)cases[i].p2, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);
    }
    et_pass();
    return 0;
}
