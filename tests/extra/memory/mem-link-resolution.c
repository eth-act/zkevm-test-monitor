/*
 * The vendor memory functions win symbol resolution.
 *
 * act-extra: link-decoy-memops
 *
 * build.sh links this guest with an archive of weak, deliberately wrong
 * memcpy/memmove/memset/memcmp placed BEFORE the vendor library, as a
 * compiler-builtins archive would be. The standard requires the vendor
 * definitions to take effect regardless of link order, so each call must
 * behave correctly. A decoy never writes and always reports "equal".
 */
#include "memops.h"

static uint8_t src[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
static uint8_t dst[16];

int main(void) {
    memcpy(dst, src, sizeof dst);
    CHECK(1, et_bytes_eq(dst, src, sizeof dst));

    memmove(dst + 1, dst, 8);
    CHECK(2, dst[1] == 1 && dst[8] == 8);

    memset(dst, 0x5a, 4);
    CHECK(3, dst[0] == 0x5a && dst[3] == 0x5a);

    CHECK(4, memcmp(src, dst, sizeof dst) != 0);

    et_pass();
    return 0;
}
