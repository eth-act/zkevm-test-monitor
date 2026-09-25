/*
 * memcpy copies exactly n bytes for every source and destination alignment,
 * including n == 0, returns dest, and writes nothing outside [dest, dest + n).
 */
#include "memops.h"

#define BIG 4096

static uint8_t src[MAX_OFFSET + BIG];
static uint8_t dst[GUARD + MAX_OFFSET + BIG + GUARD];
static uint8_t expect[sizeof dst];

static int check_copy(uint32_t id, size_t doff, size_t soff, size_t len) {
    mem_fill_pattern(src, sizeof src, len + soff);
    test_bytes_fill(dst, GUARD_BYTE, sizeof dst);
    test_bytes_fill(expect, GUARD_BYTE, sizeof expect);
    test_bytes_copy(expect + GUARD + doff, src + soff, len);

    void *ret = memcpy(dst + GUARD + doff, src + soff, len);
    if (ret != dst + GUARD + doff) {
        test_fail(id);
        return 0;
    }
    if (!test_bytes_eq(dst, expect, GUARD + MAX_OFFSET + len + GUARD)) {
        test_fail(id);
        return 0;
    }
    return 1;
}

int main(void) {
    for (size_t doff = 0; doff < MAX_OFFSET; doff++) {
        for (size_t soff = 0; soff < MAX_OFFSET; soff++) {
            for (size_t len = 0; len <= MAX_LEN; len++) {
                if (!check_copy(mem_case(0, doff, soff, len), doff, soff, len)) {
                    return 0;
                }
            }
        }
    }
    if (!check_copy(mem_case(1, 3, 5, 0), 3, 5, BIG - 1)) {
        return 0;
    }
    if (!check_copy(mem_case(1, 0, 0, 0), 0, 0, BIG)) {
        return 0;
    }
    test_pass();
    return 0;
}
