/*
 * zkvm_bn254_g1_mul: BN254 G1 scalar multiplication (EIP-196), including zero and large scalars.
 */
#include "accel.h"
#include "vectors/zkvm_bn254_g1_mul.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_bn254_g1_point out;
        test_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_bn254_g1_mul((const zkvm_bn254_g1_point *)cases[i].point,
                                               (const zkvm_bn254_scalar *)cases[i].scalar, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);
    }
    test_pass();
    return 0;
}
