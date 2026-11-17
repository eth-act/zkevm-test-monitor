// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The heap that the vendor's linker script declares is memory that the zkVM
 * accepts: the linker script "correctly describes its memory constraints,
 * including the location and size of critical memory regions such as heap
 * and stack areas".
 *
 * The heap start is less than the heap end. The guest writes and reads back
 * the first and the last 8 bytes of the heap.
 */
#include "layout.h"

#if !defined(LAYOUT_HEAP_START)
int main(void) {
    print_error("linker script declares no heap start\n");
}
#elif !defined(LAYOUT_HEAP_END)
int main(void) {
    print_error("linker script declares no heap end\n");
}
#else
int main(void) {
    uintptr_t start = layout_heap_start;
    uintptr_t end = layout_heap_end;
    CHECK_LABEL(1, "heap start < heap end", start < end);
    CHECK_LABEL(2, "first bytes of the heap", layout_write_read(start, layout_min8(end - start)));
    CHECK_LABEL(3, "last bytes of the heap",
                layout_write_read(end - layout_min8(end - start), layout_min8(end - start)));
    rvtest_pass();
    return 0;
}
#endif
