// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * A loader that zero-fills the p_memsz > p_filesz tail of a segment does not
 * overwrite a byte that came from p_filesz file data ("Initial memory state").
 *
 * For each accept-tail-<r> variant (r = 1..7), mutate_elf.py adds a
 * read-only PT_LOAD segment to this ELF: 16 + r file bytes of TAIL_BYTE,
 * then 16 bytes of zero fill. The input holds the segment's address and r
 * (two little-endian u64 values). With an empty input (elf-tail itself), the
 * guest only passes.
 */
#include "checks.h"

/* The file byte at offset i of the added segment (mutate_elf.py tail_byte). */
#define TAIL_BYTE(i) ((uint8_t)((i) * 41 + 3))
#define TAIL_ZEROS 16

static uint64_t load_u64(const uint8_t *p) {
    uint64_t value = 0;
    for (size_t i = 0; i < 8; i++) {
        value |= (uint64_t)p[i] << (8 * i);
    }
    return value;
}

int main(void) {
    const uint8_t *input;
    size_t size;
    read_input(&input, &size);
    if (size == 0) {
        rvtest_pass();
    }
    CHECK(1, size == 16);
    const volatile uint8_t *segment = (const volatile uint8_t *)(uintptr_t)load_u64(input);
    size_t file_size = 16 + (size_t)load_u64(input + 8);
    for (size_t i = 0; i < file_size; i++) {
        CHECK(2, segment[i] == TAIL_BYTE(i));
    }
    for (size_t i = file_size; i < file_size + TAIL_ZEROS; i++) {
        CHECK(3, segment[i] == 0);
    }
    rvtest_pass();
    return 0;
}
