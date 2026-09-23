/*
 * memcmp compares bytes as unsigned char, stops at the first difference,
 * ignores bytes at and after n, and returns 0 for n == 0. The sign of the
 * result follows the C standard. Every alignment of both operands is covered.
 */
#include "memops.h"

static uint8_t a[MAX_OFFSET + MAX_LEN];
static uint8_t b[MAX_OFFSET + MAX_LEN];

static int sign(int x) {
    return (x > 0) - (x < 0);
}

int main(void) {
    for (size_t aoff = 0; aoff < MAX_OFFSET; aoff++) {
        for (size_t boff = 0; boff < MAX_OFFSET; boff++) {
            for (size_t len = 0; len <= MAX_LEN; len++) {
                uint32_t id = mem_case(0, aoff, boff, len);
                mem_fill_pattern(a + aoff, len, 3);
                mem_fill_pattern(b + boff, len, 3);
                CHECK(id, memcmp(a + aoff, b + boff, len) == 0);

                /* A difference at every position: first byte smaller, then larger. */
                for (size_t k = 0; k < len; k++) {
                    uint8_t saved = b[boff + k];
                    b[boff + k] = (uint8_t)(a[aoff + k] + 1);
                    if (a[aoff + k] != 0xff) {
                        CHECK(mem_case(1, aoff, boff, len), sign(memcmp(a + aoff, b + boff, len)) < 0);
                        CHECK(mem_case(2, aoff, boff, len), sign(memcmp(b + boff, a + aoff, len)) > 0);
                    }
                    /* The difference is outside the first k bytes. */
                    CHECK(mem_case(3, aoff, boff, len), memcmp(a + aoff, b + boff, k) == 0);
                    b[boff + k] = saved;
                }
            }
        }
    }

    /* Unsigned comparison: 0x80 > 0x7f, although (signed char)0x80 < 0x7f. */
    static const uint8_t hi[2] = {0x80, 0x00};
    static const uint8_t lo[2] = {0x7f, 0xff};
    CHECK(4, sign(memcmp(hi, lo, 2)) > 0);
    CHECK(5, sign(memcmp(lo, hi, 2)) < 0);
    /* Only the first difference decides the result. */
    static const uint8_t x[3] = {1, 2, 0xff};
    static const uint8_t y[3] = {1, 3, 0x00};
    CHECK(6, sign(memcmp(x, y, 3)) < 0);
    /* n == 0 compares nothing. */
    CHECK(7, memcmp(hi, lo, 0) == 0);

    et_pass();
    return 0;
}
