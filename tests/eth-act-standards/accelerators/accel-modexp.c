/*
 * zkvm_modexp: arbitrary-precision (base^exp) mod m, with empty operands and a zero modulus.
 */
#include "accel.h"
#include "vectors/zkvm_modexp.h"

static uint8_t out[1024 + 1];

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        test_bytes_fill(out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_modexp(cases[i].base, cases[i].base_len, cases[i].exp, cases[i].exp_len,
                                         cases[i].mod, cases[i].mod_len, out);
        CHECK_OUTPUT(i, status, out, cases[i].out, cases[i].out_len);
        /* Only mod_len bytes may be written. */
        CHECK_LABEL(CASE_ID(i, 4), cases[i].label, out[cases[i].mod_len] == OUTPUT_MARKER);
    }
    test_pass();
    return 0;
}
