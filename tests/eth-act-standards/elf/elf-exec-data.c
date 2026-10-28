// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * A zkVM executes only instructions in an executable (PF_X) segment ("Code
 * and data separation"). The guest calls `addi a0, zero, 1; ret` in .data,
 * which is not executable. The call must terminate the program abnormally
 * (elf-exec-data.outcome). If it returns, the guest writes RETURNED and
 * returns from main, so the test fails.
 */
#include "checks.h"

static const uint8_t RETURNED[] = "the call returned";

/* addi a0, zero, 1; jalr zero, 0(ra) */
uint32_t exec_data_code[2] = {0x00100513, 0x00008067};

int main(void) {
    int (*code)(void) = (int (*)(void))(uintptr_t)exec_data_code;
    volatile int result = code();
    (void)result;
    write_output(RETURNED, sizeof RETURNED - 1);
    return 0;
}
