/*
 * Shared helpers for the memory safety guard region tests.
 *
 * Each access is one byte, so it touches exactly one address. The address
 * comes from a volatile variable into the register of an inline lb or sb:
 * GCC -O2 replaces a load or store through a known null pointer with a trap
 * (-fisolate-erroneous-paths-dereference), not a memory access.
 *
 * An access to a guard region must terminate the guest abnormally (.outcome:
 * fail, with any code). If the access completes, the guest calls
 * rvtest_pass(): it finishes normally, and the runner reports "did not panic".
 */
#ifndef GUARD_H
#define GUARD_H

#include "checks.h"

/* Load one byte from addr. */
static inline void guard_lb(uintptr_t addr) {
    volatile uintptr_t a = addr;
    uintptr_t p = a;
    uint64_t value;
    __asm__ volatile("lb %0, 0(%1)" : "=r"(value) : "r"(p) : "memory");
    (void)value;
}

/* Store one byte (0xa5) to addr. */
static inline void guard_sb(uintptr_t addr) {
    volatile uintptr_t a = addr;
    uintptr_t p = a;
    __asm__ volatile("sb %0, 0(%1)" : : "r"(0xa5), "r"(p) : "memory");
}

/*
 * The stack bottom, the lowest byte of the stack: the vendor linker symbol that
 * zkvms/<zkvm>/standards/layout.yaml names (symbols.stack_bottom).
 * build-guests.sh defines GUARD_STACK_BOTTOM as that symbol. A platform that
 * declares no stack bottom has no stack guard region to test, so the
 * guard-stack-* guests fail.
 */
#ifdef GUARD_STACK_BOTTOM
extern char GUARD_STACK_BOTTOM[];

static inline uintptr_t guard_stack_bottom(void) {
    return (uintptr_t)GUARD_STACK_BOTTOM;
}
#else
static inline uintptr_t guard_stack_bottom(void) {
    print_error("the platform declares no stack bottom\n");
}
#endif

#endif /* GUARD_H */
