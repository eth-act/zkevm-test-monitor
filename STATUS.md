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

**Jolt result**: 115/118 native, 64/72 target (proved 64/64, verified 62/64)
- 3 native failures: `Zca-c.slli-00`, `Zalrsc-sc.d-00`, `Zalrsc-sc.w-00` — all new tests added in 4.0.0, pre-existing jolt gaps
- 8 target Misalign failures: pre-existing (jolt doesn't support misaligned loads/stores)
- 2 target verify failures (M-divw, M-remw): pre-existing jolt proving bug

**Next step**: Apply the same 3-change Dockerfile pattern to remaining ZKVMs:
1. Repo URL → `riscv/riscv-arch-test.git`, branch → `4.0.0`
2. Remove UDB submodule init
3. Patch target → `tests/env/rvtest_setup.h`
4. Remove `uv run make tests` step
5. Check each ZKVM's sail.json for `allowed_within_exp: 12` → `11`
6. Check each ZKVM's rvmodel_macros.h for missing INTERRUPT_LATENCY/TIMER_INT_SOON_DELAY
