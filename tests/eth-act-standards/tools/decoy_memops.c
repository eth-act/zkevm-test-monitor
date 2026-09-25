/*
 * Decoy memory functions for the link-resolution test.
 *
 * They are weak, like the compiler-builtins definitions a Rust or C runtime
 * brings into a guest link, and deliberately wrong: they do nothing and
 * report "equal". A guest linked with this archive before the vendor library
 * behaves correctly only if the vendor definitions win symbol resolution.
 */

#include <stddef.h>

__attribute__((weak)) void *memcpy(void *dest, const void *src, size_t n) {
    (void)src;
    (void)n;
    return dest;
}

__attribute__((weak)) void *memmove(void *dest, const void *src, size_t n) {
    (void)src;
    (void)n;
    return dest;
}

__attribute__((weak)) void *memset(void *dest, int c, size_t n) {
    (void)c;
    (void)n;
    return dest;
}

__attribute__((weak)) int memcmp(const void *lhs, const void *rhs, size_t n) {
    (void)lhs;
    (void)rhs;
    (void)n;
    return 0;
}
