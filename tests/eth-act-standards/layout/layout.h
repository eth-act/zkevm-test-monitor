/*
 * The vendor's heap and stack symbols for the layout/ guests.
 *
 * build-guests.sh passes each symbol that zkvms/<zkvm>/standards/layout.yaml
 * declares as a macro: LAYOUT_HEAP_START, LAYOUT_HEAP_END, LAYOUT_STACK_BOTTOM
 * and LAYOUT_STACK_TOP name the vendor's linker symbols. A macro is not
 * defined when layout.yaml says none; a guest that needs it then fails with
 * "linker script declares no <bound>".
 *
 * The bounds are 64-bit data words, because -mcmodel=medany reaches a symbol
 * only within 2 GiB of the code (SP1's heap end is 0x1c00000000). They are
 * kept in every layout/ ELF (used): a linker script defines a PROVIDE()d
 * symbol only for a link that references it, so tools/check_layout.py finds
 * all declared symbols in any layout/ ELF.
 */
#ifndef LAYOUT_H
#define LAYOUT_H

#include "checks.h"

#ifdef LAYOUT_HEAP_START
extern char LAYOUT_HEAP_START[];
__attribute__((used)) static const volatile uintptr_t layout_heap_start = (uintptr_t)LAYOUT_HEAP_START;
#endif
#ifdef LAYOUT_HEAP_END
extern char LAYOUT_HEAP_END[];
__attribute__((used)) static const volatile uintptr_t layout_heap_end = (uintptr_t)LAYOUT_HEAP_END;
#endif
#ifdef LAYOUT_STACK_BOTTOM
extern char LAYOUT_STACK_BOTTOM[];
__attribute__((used)) static const volatile uintptr_t layout_stack_bottom = (uintptr_t)LAYOUT_STACK_BOTTOM;
#endif
#ifdef LAYOUT_STACK_TOP
extern char LAYOUT_STACK_TOP[];
__attribute__((used)) static const volatile uintptr_t layout_stack_top = (uintptr_t)LAYOUT_STACK_TOP;
#endif

/* Writes n bytes (n <= 8) at addr and reads them back. Byte accesses need no
 * alignment. */
static inline bool layout_write_read(uintptr_t addr, size_t n) {
    volatile uint8_t *p = (volatile uint8_t *)addr;
    for (size_t i = 0; i < n; i++) {
        p[i] = (uint8_t)(0x5a + i);
    }
    for (size_t i = 0; i < n; i++) {
        if (p[i] != (uint8_t)(0x5a + i)) {
            return false;
        }
    }
    return true;
}

static inline size_t layout_min8(uintptr_t size) {
    return size < 8 ? (size_t)size : 8;
}

#endif /* LAYOUT_H */
