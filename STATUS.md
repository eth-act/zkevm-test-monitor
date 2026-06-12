# Status: ACT4 4.0.0 upgrade

**Plan**: Bump riscv-arch-test baseline from commit b75bf1ee (act4 branch) to the 4.0.0 release tag (a7c99303).

**Current focus**: Validate jolt build/test before rolling out to remaining ZKVMs.

**What changed in 4.0.0**:
- Repo moved: `riscv-non-isa/riscv-arch-test` → `riscv/riscv-arch-test` (GitHub redirect active)
- UDB submodule removed (now a Ruby gem in the framework; we bypass UDB via extensions.txt trick)
- `tests/env/test_setup.h` renamed to `tests/env/rvtest_setup.h` (same `.option rvc` issue present)
- Test sources (`.S` files) are pre-generated and checked in — no more `make tests` generation step

**Changes made**:
- `docker/jolt/Dockerfile`: updated repo URL, clone branch, commit pin, patch target, removed UDB submodule + make-tests steps
- `config.json`: updated `act4_commit` to `a7c99303516f4e668f7488f172043392e23b9dfd`

**Next step**: Run `./run build jolt && ./run test jolt` to validate, then apply same Dockerfile pattern to remaining ZKVMs (airbender, sp1, openvm, r0vm, zisk, pico, lambdavm).

**Blocking**: None — waiting for user to run jolt tests.
