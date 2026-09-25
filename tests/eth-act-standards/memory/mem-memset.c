/*
 * memset fills n bytes with (unsigned char)c for every alignment and n == 0,
 * returns dest, and writes nothing outside [dest, dest + n).
 */
#include "memops.h"

#define BIG 4096

static uint8_t dst[GUARD + MAX_OFFSET + BIG + GUARD];
static uint8_t expect[sizeof dst];

/* Values include ones whose int form has bits above the low byte. */
static const int values[] = {0x00, 0xa5, 0xff, 0x1234, -1, -128};

static int check_set(uint32_t id, size_t doff, int c, size_t len) {
    test_bytes_fill(dst, GUARD_BYTE, sizeof dst);
    test_bytes_fill(expect, GUARD_BYTE, sizeof expect);
    test_bytes_fill(expect + GUARD + doff, (uint8_t)c, len);

    void *ret = memset(dst + GUARD + doff, c, len);
    if (ret != dst + GUARD + doff || !test_bytes_eq(dst, expect, GUARD + MAX_OFFSET + len + GUARD)) {
        test_fail(id);
        return 0;
    }
    return 1;
}

int main(void) {
    for (size_t v = 0; v < sizeof values / sizeof values[0]; v++) {
        for (size_t doff = 0; doff < MAX_OFFSET; doff++) {
            for (size_t len = 0; len <= MAX_LEN; len++) {
                if (!check_set(mem_case((uint32_t)v, doff, 0, len), doff, values[v], len)) {
                    return 0;
                }
            }
        }
    }
    if (!check_set(mem_case(7, 5, 0, 0), 5, 0x5a, BIG - 3)) {
        return 0;
    }
    test_pass();
    return 0;
}
