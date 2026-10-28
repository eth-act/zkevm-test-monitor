// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The initial memory image comes from the PT_LOAD segments ("Initial memory
 * state"): when main runs, every byte of .data holds its file data, every byte
 * of .bss (the p_memsz > p_filesz tail) holds zero, and .rodata is present and
 * readable. The guest computes each expected byte; it does not take it from
 * data.
 *
 * elf-image is the base ELF of most variants that mutate_elf.py writes. It
 * finds elf_image_data by its symbol.
 */
#include "checks.h"

#define IMAGE_SIZE 64
#define BSS_SIZE 4096

/* The byte at index i of .data and of .rodata. */
#define DATA_BYTE(i) ((uint8_t)((i) * 29 + 7))
#define RODATA_BYTE(i) ((uint8_t)((i) * 13 + 101))

#define D4(i) DATA_BYTE(i), DATA_BYTE((i) + 1), DATA_BYTE((i) + 2), DATA_BYTE((i) + 3)
#define D16(i) D4(i), D4((i) + 4), D4((i) + 8), D4((i) + 12)
#define R4(i) RODATA_BYTE(i), RODATA_BYTE((i) + 1), RODATA_BYTE((i) + 2), RODATA_BYTE((i) + 3)
#define R16(i) R4(i), R4((i) + 4), R4((i) + 8), R4((i) + 12)

uint8_t elf_image_data[IMAGE_SIZE] = {D16(0), D16(16), D16(32), D16(48)};
const uint8_t elf_image_rodata[IMAGE_SIZE] = {R16(0), R16(16), R16(32), R16(48)};
uint8_t elf_image_bss[BSS_SIZE];

int main(void) {
    /* Volatile loads, so the compiler cannot use the initializers instead. */
    const volatile uint8_t *data = elf_image_data;
    const volatile uint8_t *rodata = elf_image_rodata;
    const volatile uint8_t *bss = elf_image_bss;
    for (size_t i = 0; i < IMAGE_SIZE; i++) {
        CHECK(1, data[i] == DATA_BYTE(i));
        CHECK(2, rodata[i] == RODATA_BYTE(i));
    }
    for (size_t i = 0; i < BSS_SIZE; i++) {
        CHECK(3, bss[i] == 0);
    }
    rvtest_pass();
    return 0;
}
