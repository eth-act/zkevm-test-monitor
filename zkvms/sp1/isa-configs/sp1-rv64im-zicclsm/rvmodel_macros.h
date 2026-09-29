// rvmodel_macros.h for SP1 (RV64IM_Zicclsm ZK-VM target)
// SP1 reads the syscall number from t0 (x5); args in a0 (x10), a1 (x11):
//   t0=0x02 WRITE                  (a0=fd, a1=ptr, a2=len)
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
// SP1 has no M-mode CSRs, so STANDARD_SM_SUPPORTED stays undefined and the
// ACT4 boot code emits no CSR instructions.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .balign 8; .global tohost; tohost: .dword 0;         \
        .balign 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

// The verdict is also written to the public values, as for every zkVM on the ere
// path: "PASS" = 0x53534150 or "FAIL" = 0x4c494146 (little-endian ASCII). WRITE
// (t0=0x02) to FD_PUBLIC_VALUES (a0=13) with a1=ptr, a2=len; the marker is staged in
// `fromhost`, so .data keeps the addresses of the Sail reference build. Then COMMIT
// the SHA256 digest of those 4 bytes (8 LE words) + 8 zero deferred words, and HALT.
#define RVMODEL_SP1_HALT(_MARKER, _EXIT, _D0, _D1, _D2, _D3, _D4, _D5, _D6, _D7) \
  li t1, _MARKER ; la a1, fromhost ; sw t1, 0(a1)  ;\
  li t0, 0x02 ; li a0, 13 ; li a2, 4 ; ecall      ;\
  li t0, 0x10 ; li a0, 0 ; li a1, _D0 ; ecall      ;\
  li t0, 0x10 ; li a0, 1 ; li a1, _D1 ; ecall      ;\
  li t0, 0x10 ; li a0, 2 ; li a1, _D2 ; ecall      ;\
  li t0, 0x10 ; li a0, 3 ; li a1, _D3 ; ecall      ;\
  li t0, 0x10 ; li a0, 4 ; li a1, _D4 ; ecall      ;\
  li t0, 0x10 ; li a0, 5 ; li a1, _D5 ; ecall      ;\
  li t0, 0x10 ; li a0, 6 ; li a1, _D6 ; ecall      ;\
  li t0, 0x10 ; li a0, 7 ; li a1, _D7 ; ecall      ;\
  li t0, 0x1a ; li a0, 0 ; li a1, 0 ; ecall        ;\
  li t0, 0x1a ; li a0, 1 ; li a1, 0 ; ecall        ;\
  li t0, 0x1a ; li a0, 2 ; li a1, 0 ; ecall        ;\
  li t0, 0x1a ; li a0, 3 ; li a1, 0 ; ecall        ;\
  li t0, 0x1a ; li a0, 4 ; li a1, 0 ; ecall        ;\
  li t0, 0x1a ; li a0, 5 ; li a1, 0 ; ecall        ;\
  li t0, 0x1a ; li a0, 6 ; li a1, 0 ; ecall        ;\
  li t0, 0x1a ; li a0, 7 ; li a1, 0 ; ecall        ;\
  li t0, 0 ; li a0, _EXIT ; li a1, 0x400 ; ecall   ;\
  j .                                              ;\

// SHA256("PASS") and SHA256("FAIL") as 8 little-endian words.
#define RVMODEL_HALT_PASS RVMODEL_SP1_HALT(0x53534150, 0, \
  0x02cb9a2f, 0xbb21a1fa, 0x9521362a, 0xc6b4571f, 0x37536590, 0x5a2eeeed, 0x2bbe50c3, 0xa88ee83b)
#define RVMODEL_HALT_FAIL RVMODEL_SP1_HALT(0x4c494146, 1, \
  0xe2055342, 0x10dff95d, 0x6411018e, 0x5297caf7, 0x1bcf7622, 0xec8a7bc6, 0xcd39713a, 0x819afb60)

// SP1 has no console; the failure diagnostics are not printed.
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

// No interrupts: these are required by check_defines.h but never expanded
// without STANDARD_SM_SUPPORTED.
#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_TIMER_INT_SOON_DELAY 100
#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2)
#define RVMODEL_CLR_MSW_INT(_R1, _R2)
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif // _RVMODEL_MACROS_H
