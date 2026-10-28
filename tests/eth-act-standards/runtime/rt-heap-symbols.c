/*
 * The linker script defines _heap_start, the address of the first byte of the
 * heap region, and _heap_end, the address one past its last byte. The heap
 * bytes at both ends hold a written value.
 *
 * The references are weak, so a missing symbol fails the test, not the link.
 * The guest reads the addresses from data pointers: both linkers resolve an
 * absolute data relocation to a missing weak symbol to 0.
 */
#include "rt.h"

extern char _heap_start[] __attribute__((weak));
extern char _heap_end[] __attribute__((weak));

static char *volatile heap_start = _heap_start;
static char *volatile heap_end = _heap_end;

int main(void) {
    volatile char *start = heap_start;
    volatile char *end = heap_end;
    RT_CHECK(start != 0, "_heap_start is not defined");
    RT_CHECK(end != 0, "_heap_end is not defined");
    RT_CHECK(start <= end, "_heap_start is above _heap_end");
    if (start < end) {
        start[0] = 0x5a;
        RT_CHECK(start[0] == 0x5a, "the byte at _heap_start does not hold a written value");
        end[-1] = 0xa5;
        RT_CHECK(end[-1] == (char)0xa5, "the byte at _heap_end - 1 does not hold a written value");
    }
    RT_WRITE("PASS");
    return 0;
}
