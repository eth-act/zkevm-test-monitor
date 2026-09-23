/*
 * zkvm_blake2f: BLAKE2 compression F (EIP-152) in place, for 0 to 8000000 rounds; a final flag other than 0 or 1 must fail.
 */
#include "accel.h"
#include "vectors/zkvm_blake2f.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_blake2f_state h;
        et_bytes_copy(&h, cases[i].h, sizeof h);
        zkvm_status status = zkvm_blake2f(cases[i].rounds, &h, (const zkvm_blake2f_message *)cases[i].m,
                                          (const zkvm_blake2f_offset *)cases[i].t, (uint8_t)cases[i].f);
        CHECK_OUTPUT(i, status, &h, cases[i].out, cases[i].out_len);
    }
    et_pass();
    return 0;
}
