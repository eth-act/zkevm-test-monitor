/*
 * zkvm_keccak256: Keccak-256 digests of inputs around the 136-byte rate.
 */
#include "accel.h"
#include "vectors/zkvm_keccak256.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_keccak256_hash out;
        test_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_keccak256(cases[i].data, cases[i].data_len, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);
    }
    test_pass();
    return 0;
}
