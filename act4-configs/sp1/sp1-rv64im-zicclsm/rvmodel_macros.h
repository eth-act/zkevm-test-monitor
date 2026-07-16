// rvmodel_macros.h for SP1 (RV64IM_Zicclsm ZK-VM target)
// SP1 reads the syscall number from t0 (x5); args in a0 (x10), a1 (x11):
//   t0=0x10 COMMIT                 (a0=word_idx, a1=digest_word)
//   t0=0x1a COMMIT_DEFERRED_PROOFS (a0=word_idx, a1=digest_word)
//   t0=0    HALT                   (a0=exit code)
// PASS: HALT a0=0 (success); FAIL: HALT a0=1 (non-zero).
//
// SP1's core-proof verifier (crates/sdk/src/prover.rs) requires the guest to
// COMMIT a public-values digest equal to SHA256(public_values) and to invoke
// COMMIT_DEFERRED_PROOFS before HALT, else verification fails with
// InvalidPublicValues ("committed value digest doesnt match"). This mirrors
// SP1's own syscall_halt epilogue (crates/zkvm/entrypoint/.../syscalls/halt.rs):
// commit the 8 little-endian words of the digest, then 8 deferred words, then
// HALT. Compliance tests write nothing to the public-values fd, so the digest is
// SHA256("") = e3b0c442...b855; the 8 LE u32 words are hard-coded below, and the
// deferred digest is all-zero (the no-`verify`-feature path). All three syscalls
// are NO-OPS in SP1's MinimalExecutor, so execution (native suite) results are
// unchanged; they only populate the public values consumed during proving.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .align 8; .global tohost; tohost: .dword 0;         \
        .align 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

#define RVMODEL_BOOT

// COMMIT the SHA256("") public-values digest (8 LE words) + 8 zero deferred words.
#define RVMODEL_SP1_COMMIT_PV                          \
  li t0, 0x10 ; li a0, 0 ; li a1, 0x42c4b0e3 ; ecall ;\
  li t0, 0x10 ; li a0, 1 ; li a1, 0x141cfc98 ; ecall ;\
  li t0, 0x10 ; li a0, 2 ; li a1, 0xc8f4fb9a ; ecall ;\
  li t0, 0x10 ; li a0, 3 ; li a1, 0x24b96f99 ; ecall ;\
  li t0, 0x10 ; li a0, 4 ; li a1, 0xe441ae27 ; ecall ;\
  li t0, 0x10 ; li a0, 5 ; li a1, 0x4c939b64 ; ecall ;\
  li t0, 0x10 ; li a0, 6 ; li a1, 0x1b9995a4 ; ecall ;\
  li t0, 0x10 ; li a0, 7 ; li a1, 0x55b85278 ; ecall ;\
  li t0, 0x1a ; li a0, 0 ; li a1, 0 ; ecall          ;\
  li t0, 0x1a ; li a0, 1 ; li a1, 0 ; ecall          ;\
  li t0, 0x1a ; li a0, 2 ; li a1, 0 ; ecall          ;\
  li t0, 0x1a ; li a0, 3 ; li a1, 0 ; ecall          ;\
  li t0, 0x1a ; li a0, 4 ; li a1, 0 ; ecall          ;\
  li t0, 0x1a ; li a0, 5 ; li a1, 0 ; ecall          ;\
  li t0, 0x1a ; li a0, 6 ; li a1, 0 ; ecall          ;\
  li t0, 0x1a ; li a0, 7 ; li a1, 0 ; ecall          ;\

#define RVMODEL_HALT_PASS  \
  RVMODEL_SP1_COMMIT_PV     \
  li t0, 0                ;\
  li a0, 0                ;\
  li a1, 0x400            ;\
  ecall                   ;\
  j .                     ;\

#define RVMODEL_HALT_FAIL \
  RVMODEL_SP1_COMMIT_PV     \
  li t0, 0                ;\
  li a0, 1                ;\
  li a1, 0x400            ;\
  ecall                   ;\
  j .                     ;\

#define RVMODEL_IO_INIT(_R1, _R2, _R3)

#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000

#define RVMODEL_INTERRUPT_LATENCY 10

#define RVMODEL_TIMER_INT_SOON_DELAY 100

#define RVMODEL_MTIME_ADDRESS    0x02004000

#define RVMODEL_MTIMECMP_ADDRESS 0x02000000

#define RVMODEL_SET_MEXT_INT

#define RVMODEL_CLR_MEXT_INT

#define RVMODEL_SET_MSW_INT

#define RVMODEL_CLR_MSW_INT

#define RVMODEL_SET_SEXT_INT

#define RVMODEL_CLR_SEXT_INT

#define RVMODEL_SET_SSW_INT

#define RVMODEL_CLR_SSW_INT

#endif // _COMPLIANCE_MODEL_H
