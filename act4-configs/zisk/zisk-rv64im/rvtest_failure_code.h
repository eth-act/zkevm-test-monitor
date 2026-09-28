# rvtest_failure_code.h (minimal DUT override for ZisK)
# Replaces ACT4's default diagnostic failure handler with a jump to
# rvmodel_halt_fail (RVMODEL_HALT_FAIL). The default handler reads the .word
# pointers placed after each jal failedtest_* call. patch_elfs.py replaces
# those words with NOPs (ZisK's transpiler cannot decode them), so the
# default handler would dereference 0x0000001300000013 and ziskemu would
# panic before the FAIL marker is written.
# ACT4's riscv_arch_test.h includes "rvtest_failure_code.h" with quotes, which
# resolves tests/env/rvtest_failure_code.h before dut_include_dir. The ZisK
# entrypoint therefore copies this file over tests/env/rvtest_failure_code.h.
# The verdict is the PASS/FAIL marker that RVMODEL_HALT_PASS/FAIL store at
# OUTPUT_ADDR, so the diagnostic strings are not needed.
# This file must define every symbol that ACT4 references outside
# rvtest_failure_code.h (signature.h, rvtest_setup.h).

.macro RVTEST_FAILURE_CODE
    failedtest_x5_x4:
    failedtest_x8_x7:
    failedtest_x14_x13:
    failedtest_trap_x7_x9:
    failedtest_fp_x5_x4:
    failedtest_fp_x8_x7:
    failedtest_fp_x14_x13:
    failedtest_fflags_x5_x4:
    failedtest_fflags_x8_x7:
    failedtest_fflags_x14_x13:
    failedtest_hex_to_str:
        j rvmodel_halt_fail
.endm

.macro RVTEST_FAILURE_DATA
    .data
    .balign 4
    successstr:
    abortstr:
    failstr:
    begin_debugstr:
    endstr:
    regular_sig_offset_header:
    regular_sig_offset_actual_str:
    regular_sig_offset_expected_str:
    ascii_buffer:
    canary_mismatch:
        .asciz ""
.endm
