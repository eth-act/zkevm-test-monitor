// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * A guest cannot rely on self-modifying code ("Code and data separation"),
 * and on a PF_X | PF_R zkVM a load from code returns the same byte that
 * executes there ("Segment permissions"). The guest stores the encoding of
 * `addi a0, zero, 2` over the first instruction of text_patch_fn
 * (`addi a0, zero, 1; ret`), calls the function, and loads the patched word.
 * Two results conform (elf-text-patch.outcome: pass-or-fail):
 * - the store or the load terminates the program abnormally (on a PF_X zkVM,
 *   the load does);
 * - the call returns 1 (the old code ran), and the load gives the old word.
 * If the new code runs, the guest writes SMC and returns from main. If the
 * load gives another word than the one that ran, the guest returns from main.
 * Both end without the PASS verdict, so the test fails.
 */
#include "checks.h"

int text_patch_fn(void);

__asm__(
    "    .pushsection .text.text_patch_fn, \"ax\", @progbits\n"
    "    .globl text_patch_fn\n"
    "    .p2align 2\n"
    "    .option push\n"
    "    .option norvc\n"
    "text_patch_fn:\n"
    "    addi a0, zero, 1\n"
    "    ret\n"
    "    .option pop\n"
    "    .popsection\n");

/* The I-type encoding of `addi rd, zero, imm`. */
static uint32_t addi_zero(uint32_t rd, uint32_t imm) {
    return (imm << 20) | (rd << 7) | 0x13;
}

int main(void) {
    volatile uint32_t *code = (volatile uint32_t *)(uintptr_t)&text_patch_fn;
    code[0] = addi_zero(10, 2);
    int result = text_patch_fn();
    if (result == 2) {
        write_output((const uint8_t *)"SMC", 3);
        return 0;
    }
    if (result != 1 || code[0] != addi_zero(10, 1)) {
        return 0;
    }
    rvtest_pass();
    return 0;
}
