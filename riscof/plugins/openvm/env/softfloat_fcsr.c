/*============================================================================

RISC-V Floating-Point Control and Status Register (FCSR) implementation
for SoftFloat library.

This file defines the platform-specific floating-point state variables
and exception handling for RISC-V.

=============================================================================*/

#include <stdint.h>

// Floating-point exception flags (FCSR fflags field)
uint_fast8_t softfloat_exceptionFlags = 0;

// Floating-point rounding mode (FCSR frm field)
// Default: round to nearest, ties to even (RNE)
uint_fast8_t softfloat_roundingMode = 0;

// Tininess detection mode
// 0 = detect tininess after rounding (RISC-V default)
// 1 = detect tininess before rounding
uint_fast8_t softfloat_detectTininess = 0;

// Extended precision rounding precision (for x87, not used in RISC-V)
uint_fast8_t extF80_roundingPrecision = 80;

// Floating-point exception flag raising function
// For RISC-V, we simply accumulate exception flags in the FCSR
void softfloat_raiseFlags(uint_fast8_t flags)
{
    softfloat_exceptionFlags |= flags;
}
