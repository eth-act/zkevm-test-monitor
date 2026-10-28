// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * On a PF_X | PF_R zkVM, read-only data may share the executable segment with
 * code, and a load returns the real bytes ("Segment permissions"). The asm
 * function text_data_fn holds the word 0x00000000, which is not an
 * instruction, after its `ret`. The loader accepts the ELF, and the guest
 * loads the word. build-guests.sh builds this test only for PF_X | PF_R
 * zkVMs (ELF_EXEC_PERM=rx).
 */
#include "checks.h"

int text_data_fn(void);
extern const uint32_t text_data_word;

__asm__(
    "    .pushsection .text.text_data_fn, \"ax\", @progbits\n"
    "    .globl text_data_fn\n"
    "    .globl text_data_word\n"
    "    .p2align 2\n"
    "    .option push\n"
    "    .option norvc\n"
    "text_data_fn:\n"
    "    addi a0, zero, 7\n"
    "    ret\n"
    "text_data_word:\n"
    "    .word 0x00000000\n"
    "    .option pop\n"
    "    .popsection\n");

int main(void) {
    const volatile uint32_t *word = &text_data_word;
    CHECK(1, text_data_fn() == 7);
    CHECK(2, *word == 0);
    rvtest_pass();
    return 0;
}
