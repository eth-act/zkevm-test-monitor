# ISA suite requirement IDs

`reference.req` names the requirement IDs (eth-act/zkevm-standards `standards/riscv-target/target.md`)
that the ACT4 ISA suites check (`./run isa-tests`): the Full ISA suite (`I`, `M`) and the
Standard ISA suite (`I`, `M`, `Misalign`) run in machine mode with no environment, built for
`rv64im_zicclsm`, and the `Misalign` tests need misaligned loads and stores to succeed.
`tests/eth-act-standards/tools/check_requirements.py` reads it with the `.req` files of the
standards tests.
