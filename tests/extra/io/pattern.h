/* Deterministic byte pattern shared by the I/O tests and sidecars.py. */
#ifndef IO_PATTERN_H
#define IO_PATTERN_H

#include <stddef.h>
#include <stdint.h>

static inline uint8_t io_pattern(size_t i) {
    return (uint8_t)(i * 37u + 11u + (i >> 8));
}

#endif /* IO_PATTERN_H */
