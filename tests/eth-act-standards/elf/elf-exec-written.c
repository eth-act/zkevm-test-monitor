// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * A guest cannot write bytes to memory and then execute them ("Code and data
 * separation"). The guest writes `addi a0, zero, 1; ret` to .bss and calls
 * it. The call must terminate the program abnormally
 * (elf-exec-written.outcome). If it returns, the guest writes RETURNED and
 * returns from main, so the test fails.
 */
#include "checks.h"

static const uint8_t RETURNED[] = "the call returned";

uint32_t exec_written_code[2];

int main(void) {
    volatile uint32_t *code = exec_written_code;
    code[0] = (1u << 20) | (10u << 7) | 0x13; /* addi a0, zero, 1 */
    code[1] = (1u << 15) | 0x67;              /* jalr zero, 0(ra) */
    int (*fn)(void) = (int (*)(void))(uintptr_t)exec_written_code;
    volatile int result = fn();
    (void)result;
    write_output(RETURNED, sizeof RETURNED - 1);
    return 0;
}
