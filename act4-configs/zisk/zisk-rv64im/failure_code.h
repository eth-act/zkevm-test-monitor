# failure_code.h (minimal DUT override for ZisK)
# Replaces ACT4's default diagnostic failure handler with a bare halt.
# The default handler reads the .word pointers placed after each
# jal failedtest_* call. patch_elfs.py replaces those words with NOPs
# (ZisK's transpiler cannot decode them), so the default handler would
# dereference 0x0000001300000013 and ziskemu would panic.
# ACT4's riscv_arch_test.h includes "failure_code.h" with quotes, which
# resolves tests/env/failure_code.h before dut_include_dir. The ZisK
# entrypoint therefore copies this file over tests/env/failure_code.h.
# The handler jumps to rvmodel_halt_fail (RVMODEL_HALT_FAIL). The verdict
# is the PASS/FAIL marker that RVMODEL_HALT_PASS/FAIL store
# at OUTPUT_ADDR, so the diagnostic strings are not needed.
# This file must define every symbol that ACT4 references outside
# failure_code.h (signature.h, rvtest_setup.h, rvtest_trap_handler.h).

.macro RVTEST_FAILURE_CODE
    failedtest_x5_x4:
    failedtest_x8_x7:
    failedtest_x13_x12:
    failedtest_trap_x7_x9:
    failedtest_fp_x5_x4:
    failedtest_fp_x8_x7:
    failedtest_fp_x13_x12:
    failedtest_fflags_x5_x4:
    failedtest_fflags_x8_x7:
    failedtest_fflags_x13_x12:
        j rvmodel_halt_fail
.endm

.macro RVTEST_FAILURE_DATA
    .data
    .align 4
    successstr:
    abortstr:
    trap_sig_offset_mismatch:
    canary_mismatch:
    sv_Mvect_str:
    sv_Svect_str:
    sv_Hvect_str:
    sv_Vvect_str:
    sv_Mcause_str:
    sv_Scause_str:
    sv_Hcause_str:
    sv_Vcause_str:
    sv_Mepc_str:
    sv_Sepc_str:
    sv_Hepc_str:
    sv_Vepc_str:
    sv_Mtval_str:
    sv_Stval_str:
    sv_Htval_str:
    sv_Vtval_str:
    sv_Mtval2_str:
    sv_Mtinst_str:
    sv_Mip_str:
    sv_Sip_str:
    sv_Hip_str:
    sv_Vip_str:
    Mclr_Mext_int_str:
    Mclr_Sext_int_str:
    Mclr_Vext_int_str:
    Sclr_Mext_int_str:
    Sclr_Sext_int_str:
    Sclr_Vext_int_str:
    Hclr_Mext_int_str:
    Hclr_Sext_int_str:
    Hclr_Vext_int_str:
    Vclr_Mext_int_str:
    Vclr_Sext_int_str:
    Vclr_Vext_int_str:
        .asciz ""
.endm
