// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * zkvm_modexp: arbitrary-precision (base^exp) mod m, with empty operands and a zero modulus.
 */
#include "accel.h"
#include "vectors/zkvm_modexp.h"

static uint8_t out[1024 + 1];

/* Operands of up to 1024 bytes each, and the output, at misaligned addresses. */
static _Alignas(8) uint8_t moved_base[1024 + 8], moved_exp[1024 + 8], moved_mod[1024 + 8], moved_out[1024 + 8 + 1];

int main(void) {
    for (size_t i = 0; i < NUM_CASES; i++) {
        test_bytes_fill(out, OUTPUT_MARKER, sizeof out);
        zkvm_status status = zkvm_modexp(cases[i].base, cases[i].base_len, cases[i].exp, cases[i].exp_len,
                                         cases[i].mod, cases[i].mod_len, out);
        CHECK_OUTPUT(i, status, out, cases[i].out, cases[i].out_len);
        /* Only mod_len bytes may be written. */
        CHECK_LABEL(CASE_ID(i, 4), cases[i].label, out[cases[i].mod_len] == OUTPUT_MARKER);

        /* The same case with each buffer at a different misaligned address. */
        size_t off = UNALIGNED_OFFSET(i);
        const uint8_t *b = unaligned_copy(moved_base, sizeof moved_base, cases[i].base, cases[i].base_len, off);
        const uint8_t *e = unaligned_copy(moved_exp, sizeof moved_exp, cases[i].exp, cases[i].exp_len, (off + 2) % 7 + 1);
        const uint8_t *m = unaligned_copy(moved_mod, sizeof moved_mod, cases[i].mod, cases[i].mod_len, (off + 4) % 7 + 1);
        uint8_t *o = moved_out + off;
        test_bytes_fill(moved_out, OUTPUT_MARKER, sizeof moved_out);
        status = zkvm_modexp(b, cases[i].base_len, e, cases[i].exp_len, m, cases[i].mod_len, o);
        CHECK_OUTPUT_AT(i, STEP_UNALIGNED, status, o, cases[i].out, cases[i].out_len);
        CHECK_LABEL(CASE_ID(i, STEP_UNALIGNED + 4), cases[i].label, o[cases[i].mod_len] == OUTPUT_MARKER);
    }
    rvtest_pass();
    return 0;
}
