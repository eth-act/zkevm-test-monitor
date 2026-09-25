/*
 * zkvm_ripemd160: RIPEMD-160 digests, returned in the last 20 of 32 bytes after 12 zero bytes.
 */
#include "accel.h"
#include "vectors/zkvm_ripemd160.h"

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_ripemd160_hash out;
        test_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_ripemd160(cases[i].data, cases[i].data_len, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);
    }
    test_pass();
    return 0;
}
