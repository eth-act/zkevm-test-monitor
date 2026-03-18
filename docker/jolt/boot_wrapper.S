/* Jolt ZeroOS boot code wrapper for ACT4 tests.
 *
 * Includes the pre-compiled jolt boot binary (from a minimal jolt guest)
 * and patches the termination point (j .) to jump to the ACT4 test's
 * rvtest_entry_point instead.
 *
 * Layout:
 *   0x00-0x3F: ZeroOS boot (gp/sp setup, __platform_bootstrap)
 *   0x40-0x43: j rvtest_entry_point (replaces original j . + unimp)
 *   0x44+:     ZeroOS library functions (heap init, etc.)
 */
    .section .text.boot, "ax"
    .globl _start
_start:
    .incbin "boot.bin", 0, 0x40
    j rvtest_entry_point
    .incbin "boot.bin", 0x44
