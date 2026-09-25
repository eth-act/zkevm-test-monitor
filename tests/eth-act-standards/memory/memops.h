/*
 * Shared helpers for the memory-operation tests.
 *
 * The standard functions are declared here rather than through <string.h>, so
 * guests stay freestanding. References are computed with volatile byte loops
 * that the compiler cannot turn back into calls to the functions under test.
 */
#ifndef MEMOPS_H
#define MEMOPS_H

#include "test_verdict.h"

void *memcpy(void *dest, const void *src, size_t n);
void *memmove(void *dest, const void *src, size_t n);
void *memset(void *dest, int c, size_t n);
int memcmp(const void *lhs, const void *rhs, size_t n);

/* Offsets 0..7 cover every alignment of an 8-byte word. */
#define MAX_OFFSET 8
/* Lengths 0..72 cover empty, sub-word, word-multiple and odd tails. */
#define MAX_LEN 72
/* Guard bytes on each side detect writes outside [dest, dest + n). */
#define GUARD 16
#define GUARD_BYTE 0xee

static inline uint8_t mem_pattern(size_t i) {
    return (uint8_t)(i * 151u + 7u);
}

static inline void mem_fill_pattern(uint8_t *buf, size_t n, size_t seed) {
    volatile uint8_t *b = buf;
    for (size_t i = 0; i < n; i++) {
        b[i] = mem_pattern(i + seed);
    }
}

/* Case id: which sweep, then destination offset, source offset and length. */
static inline uint32_t mem_case(uint32_t sweep, size_t doff, size_t soff, size_t len) {
    return (((sweep * MAX_OFFSET + (uint32_t)doff) * MAX_OFFSET + (uint32_t)soff) << 8) | (uint32_t)len;
}

#endif /* MEMOPS_H */
