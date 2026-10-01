// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * memcmp compares bytes as unsigned char, stops at the first difference,
 * ignores bytes at and after n, and returns 0 for n == 0. The sign of the
 * result follows the C standard, and memcmp writes nothing in or around
 * either operand. Every alignment of both operands is covered.
 */
#include "memops.h"

/* Guard bytes on each side of both operands. */
#define AREA (GUARD + MAX_OFFSET + MAX_LEN + GUARD)

static uint8_t a_area[AREA];
static uint8_t b_area[AREA];
static uint8_t *const a = a_area + GUARD;
static uint8_t *const b = b_area + GUARD;

static uint8_t a_before[AREA];
static uint8_t b_before[AREA];

static int sign(int x) {
    return (x > 0) - (x < 0);
}

/*
 * memcmp, and fail check `id` if the call wrote anywhere in either operand's
 * area: inside or after the compared range, or in the guard bytes.
 */
static int checked_memcmp(uint32_t id, const uint8_t *lhs, const uint8_t *rhs, size_t n) {
    test_bytes_copy(a_before, a_area, AREA);
    test_bytes_copy(b_before, b_area, AREA);
    int result = memcmp(lhs, rhs, n);
    CHECK(id, test_bytes_eq(a_area, a_before, AREA) && test_bytes_eq(b_area, b_before, AREA));
    return result;
}

int main(void) {
    for (size_t aoff = 0; aoff < MAX_OFFSET; aoff++) {
        for (size_t boff = 0; boff < MAX_OFFSET; boff++) {
            for (size_t len = 0; len <= MAX_LEN; len++) {
                uint32_t id = mem_case(0, aoff, boff, len);
                mem_fill_pattern(a + aoff, len, 3);
                mem_fill_pattern(b + boff, len, 3);
                CHECK(id, checked_memcmp(id, a + aoff, b + boff, len) == 0);

                /* A difference at every position: first byte smaller, then larger. */
                for (size_t k = 0; k < len; k++) {
                    uint8_t saved = b[boff + k];
                    b[boff + k] = (uint8_t)(a[aoff + k] + 1);
                    if (a[aoff + k] != 0xff) {
                        uint32_t id1 = mem_case(1, aoff, boff, len);
                        CHECK(id1, sign(checked_memcmp(id1, a + aoff, b + boff, len)) < 0);
                        uint32_t id2 = mem_case(2, aoff, boff, len);
                        CHECK(id2, sign(checked_memcmp(id2, b + boff, a + aoff, len)) > 0);
                    }
                    /* The difference is outside the first k bytes. */
                    uint32_t id3 = mem_case(3, aoff, boff, len);
                    CHECK(id3, checked_memcmp(id3, a + aoff, b + boff, k) == 0);
                    b[boff + k] = saved;
                }
            }
        }
    }

    /* Unsigned comparison: 0x80 > 0x7f, although (signed char)0x80 < 0x7f. */
    static const uint8_t hi[2] = {0x80, 0x00};
    static const uint8_t lo[2] = {0x7f, 0xff};
    test_bytes_copy(a, hi, sizeof hi);
    test_bytes_copy(b, lo, sizeof lo);
    CHECK(4, sign(checked_memcmp(4, a, b, 2)) > 0);
    CHECK(5, sign(checked_memcmp(5, b, a, 2)) < 0);
    /* Only the first difference decides the result. */
    static const uint8_t x[3] = {1, 2, 0xff};
    static const uint8_t y[3] = {1, 3, 0x00};
    test_bytes_copy(a, x, sizeof x);
    test_bytes_copy(b, y, sizeof y);
    CHECK(6, sign(checked_memcmp(6, a, b, 3)) < 0);
    /* n == 0 compares nothing and writes nothing. */
    CHECK(7, checked_memcmp(7, a, b, 0) == 0);

    rvtest_pass();
    return 0;
}
