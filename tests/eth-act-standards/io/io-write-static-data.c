// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * write_output reads its bytes from any of the guest's data sections: the
 * guest writes a constant from .rodata, an initialized array from .data and a
 * zero-initialized array from .bss, which it fills at run time.
 */
#include "checks.h"
#include "pattern.h"

#define BSS_SIZE 16

/* Each write leaves out the string's terminating NUL. */
static const uint8_t from_rodata[] = "bytes from .rodata;";
static uint8_t from_data[] = "bytes from .data;";
static uint8_t from_bss[BSS_SIZE];

int main(void) {
    for (size_t i = 0; i < BSS_SIZE; i++) {
        from_bss[i] = io_pattern(i);
    }
    write_output(from_rodata, sizeof from_rodata - 1);
    write_output(from_data, sizeof from_data - 1);
    write_output(from_bss, BSS_SIZE);
    return 0;
}
