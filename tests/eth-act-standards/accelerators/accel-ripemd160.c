// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * zkvm_ripemd160: RIPEMD-160 digests, returned in the last 20 of 32 bytes after 12 zero bytes.
 */
#include "accel.h"
#include "vectors/zkvm_ripemd160.h"

/* The largest input is 10,000 bytes (ripemd160). */
static _Alignas(8) uint8_t moved_data[10000 + 8];

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        zkvm_ripemd160_hash out;
        test_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_ripemd160(cases[i].data, cases[i].data_len, &out);
        CHECK_OUTPUT(i, status, &out, cases[i].out, cases[i].out_len);

        /* The same input at a misaligned address. */
        const uint8_t *moved = unaligned_copy(moved_data, sizeof moved_data, cases[i].data, cases[i].data_len, UNALIGNED_OFFSET(i));
        test_bytes_fill(&out, OUTPUT_MARKER, sizeof out);
        status = zkvm_ripemd160(moved, cases[i].data_len, &out);
        CHECK_OUTPUT_AT(i, STEP_UNALIGNED, status, &out, cases[i].out, cases[i].out_len);
    }
    rvtest_pass();
    return 0;
}
