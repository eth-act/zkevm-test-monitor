// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * The stack that the vendor's linker script declares is the stack that the
 * guest runs on, and it is memory that the zkVM accepts: the linker script
 * "correctly describes its memory constraints, including the location and
 * size of critical memory regions such as heap and stack areas".
 *
 * The stack bottom is less than the stack top, and sp at main is in the
 * declared stack. The guest writes and reads back the lowest 8 bytes of the
 * stack.
 */
#include "layout.h"

#if !defined(LAYOUT_STACK_BOTTOM)
int main(void) {
    print_error("linker script declares no stack bottom\n");
}
#elif !defined(LAYOUT_STACK_TOP)
int main(void) {
    print_error("linker script declares no stack top\n");
}
#else
int main(void) {
    uintptr_t bottom = layout_stack_bottom;
    uintptr_t top = layout_stack_top;
    uintptr_t sp;
    __asm__ volatile("mv %0, sp" : "=r"(sp));
    CHECK_LABEL(1, "stack bottom < stack top", bottom < top);
    CHECK_LABEL(2, "sp at main in the stack", bottom <= sp && sp <= top);
    CHECK_LABEL(3, "lowest bytes of the stack", layout_write_read(bottom, layout_min8(top - bottom)));
    rvtest_pass();
    return 0;
}
#endif
