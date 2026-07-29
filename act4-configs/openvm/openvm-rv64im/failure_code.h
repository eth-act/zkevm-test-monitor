# failure_code.h (minimal DUT override)
# Replaces the default diagnostic failure handler with a bare halt.
# The default failure_code.h decodes the failing instruction by reading
# bytes from .text via lhu (breaks on execute-only mappings like Zisk) and
# branches through CSR instructions in the trap path (rejected at load time
# by transpiler-based ZK-VMs like SP1/Pico/OpenVM/LambdaVM).
# Since RVMODEL_IO_WRITE_STR is a no-op on all these VMs anyway, the
# diagnostic output is never visible; the only thing that matters is the
# exit code (0 = pass, 1 = fail).

.macro RVTEST_FAILURE_CODE
    failedtest_x5_x4:
    failedtest_x8_x7:
    failedtest_x13_x12:
    failedtest_saveregs:
    failedtest_saveresults:
    failedtest_report:
    failedtest_terminate:
        RVMODEL_HALT_FAIL
.endm

.macro RVTEST_FAILURE_DATA
    .data
    .align 4
    successstr:
        .asciz ""
.endm
