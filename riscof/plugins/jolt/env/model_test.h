#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

// Define RISC-V XLEN
#define __riscv_xlen 32
#define TESTNUM x31

// Boot macro - empty for Jolt
#define RVMODEL_BOOT

// Critical: Data markers MUST be in data sections, not text!
#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .align 8; .global begin_regstate; begin_regstate: .word 128;    \
        .align 8; .global end_regstate; end_regstate: .word 4;          \
        .popsection;

// Jolt-specific halt: write to tohost to signal test completion
// Uses HTIF protocol: device=0, cmd=0, payload=1 (LSB set = done, exit_code=0)
#define RVMODEL_HALT                                                     \
  fence;                                                                 \
  la t1, begin_signature;                                               \
  la t2, end_signature;                                                  \
  li TESTNUM, 1;                                                        \
  li t0, 1;          /* payload = 1 (LSB set = done, exit_code = 0) */  \
  la t1, tohost;                                                        \
  sw t0, 0(t1);      /* Write to tohost to signal completion */         \
self_loop:  j self_loop;

#define RVMODEL_DATA_BEGIN                                              \
  .section .text;                                                       \
  .balign 4;                                                           \
  RVMODEL_DATA_SECTION                                                  \
  .section .data;                                                       \
  .balign 4;                                                           \
  .global begin_signature; begin_signature:

#define RVMODEL_DATA_END                                                \
  .align 4;                                                           \
  .global end_signature; end_signature:

// IO macros (no-ops for Jolt)
#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_SP, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_SP, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)
#define RVMODEL_SET_MSB_INT
#define RVMODEL_CLEAR_MSB_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

// Pass/Fail macros
#define RVTEST_PASS                                                     \
        fence;                                                          \
        li TESTNUM, 1;                                                  \
        li a7, 93;                                                      \
        li a0, 0;

#define RVTEST_FAIL                                                     \
        fence;                                                          \
        li TESTNUM, 1;                                                  \
        li a7, 93;                                                      \
        li a0, 1;

#endif // _COMPLIANCE_MODEL_H