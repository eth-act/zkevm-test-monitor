/*
 * zkvm_sha256: SHA-256 digests of inputs around the 64-byte block and padding limits.
 */
#include "accel.h"
#include "vectors/zkvm_sha256.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_sha256_hash out;
        et_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_sha256(cases[i].data, cases[i].data_len, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);
    }
    et_pass();
    return 0;
}
