// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * A load from the executable segment ("Segment permissions"):
 * - on a PF_X | PF_R zkVM, the load returns the real bytes. The guest calls
 *   text_read_fn, then loads its first instruction word and compares it with
 *   the encoding of `addi a0, zero, 42`, which it computes;
 * - on a PF_X zkVM, the load terminates the program abnormally, even though
 *   the word is a valid instruction. build-guests.sh gives the test the
 *   outcome `fail` there.
 * A failed check therefore returns from main without the PASS verdict: an
 * abnormal termination would pass the test on a PF_X zkVM.
 */
#include "checks.h"

int text_read_fn(void);

__asm__(
    "    .pushsection .text.text_read_fn, \"ax\", @progbits\n"
    "    .globl text_read_fn\n"
    "    .p2align 2\n"
    "    .option push\n"
    "    .option norvc\n"
    "text_read_fn:\n"
    "    addi a0, zero, 42\n"
    "    ret\n"
    "    .option pop\n"
    "    .popsection\n");

/* The I-type encoding of `addi rd, zero, imm`. */
static uint32_t addi_zero(uint32_t rd, uint32_t imm) {
    return (imm << 20) | (rd << 7) | 0x13;
}

int main(void) {
    const volatile uint32_t *code = (const volatile uint32_t *)(uintptr_t)&text_read_fn;
    if (text_read_fn() != 42 || *code != addi_zero(10, 42)) {
        return 0;
    }
    rvtest_pass();
    return 0;
}
