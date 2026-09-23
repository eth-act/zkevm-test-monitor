/*
 * memmove behaves as if it copied through a temporary buffer: correct for
 * disjoint regions and for overlap in both directions, for every alignment
 * and n == 0. It returns dest and writes nothing outside [dest, dest + n).
 */
#include "memops.h"

/* Source-to-destination shifts from -SHIFT to +SHIFT exercise both overlap directions. */
#define SHIFT 12
#define BUF (GUARD + SHIFT + MAX_OFFSET + MAX_LEN + SHIFT + GUARD)

static uint8_t buf[BUF];
static uint8_t tmp[MAX_LEN];
static uint8_t expect[BUF];

int main(void) {
    for (int shift = -SHIFT; shift <= SHIFT; shift++) {
        for (size_t soff = 0; soff < MAX_OFFSET; soff++) {
            for (size_t len = 0; len <= MAX_LEN; len++) {
                size_t src = GUARD + SHIFT + soff;
                size_t dst = (size_t)((long)src + shift);
                uint32_t id = mem_case((uint32_t)(shift + SHIFT), 0, soff, len);

                mem_fill_pattern(buf, BUF, len + soff);
                et_bytes_copy(expect, buf, BUF);
                et_bytes_copy(tmp, buf + src, len);
                et_bytes_copy(expect + dst, tmp, len);

                void *ret = memmove(buf + dst, buf + src, len);
                CHECK(id, ret == buf + dst);
                CHECK(id, et_bytes_eq(buf, expect, BUF));
            }
        }
    }
    et_pass();
    return 0;
}
