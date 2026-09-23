/*
 * zkvm_kzg_point_eval: KZG point evaluation (EIP-4844); a wrong evaluation, proof or field element must not verify.
 */
#include "accel.h"
#include "vectors/zkvm_kzg_point_eval.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        bool verified = false;
        zkvm_status status = zkvm_kzg_point_eval((const zkvm_kzg_commitment *)cases[i].commitment,
                                                 (const zkvm_kzg_field_element *)cases[i].z,
                                                 (const zkvm_kzg_field_element *)cases[i].y,
                                                 (const zkvm_kzg_proof *)cases[i].proof, &verified);
        CHECK_VERDICT(i, status, verified);
    }
    et_pass();
    return 0;
}
