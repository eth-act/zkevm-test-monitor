# Status: ACT4 4.0.0 upgrade

**Plan**: Bump riscv-arch-test baseline from commit b75bf1ee (act4 branch) to the 4.0.0 release tag (a7c99303).

**Current focus**: Upgrading each ZKVM Dockerfile + configs to ACT4 4.0.0.

**What changed in 4.0.0** (applied to each ZKVM):
- Repo moved: `riscv-non-isa/riscv-arch-test` → `riscv/riscv-arch-test`
- UDB submodule removed — no more `git submodule update --init external/riscv-unified-db`
- `tests/env/test_setup.h` → `tests/env/rvtest_setup.h` (same `.option rvc` patch still needed)
- Test sources pre-generated in repo — no more `uv run make tests` in Dockerfile
- sail.json schema: `allowed_within_exp` max reduced from 12 → 11
- New required macros: `RVMODEL_INTERRUPT_LATENCY 10`, `RVMODEL_TIMER_INT_SOON_DELAY 100`

**Progress**:
- [x] jolt — upgraded + tested (115/118 native, 64/72 target)
- [x] zisk — upgraded + tested (315/318 native execute; 70/72 target full/GPU — I-fence-00 expected, Zcd-c.fldsp/c.fsdsp fail, I-auipc-00 prove=failed)
- [x] lambdavm — upgraded + tested (58/64 native, 66/72 target — same 6 branch failures as before, pre-existing LambdaVM bug)
- [x] sp1 — upgraded + tested (62/64 native, 62/72 target — same failures as 3.x: I-auipc-00, I-fence-00, Misalign-*)
- [ ] airbender — pending
- [ ] openvm — pending
- [ ] r0vm — pending
- [ ] pico — pending

**Next step**: Upgrade pico to 4.0.0 (sp1 done; airbender/openvm/r0vm/pico remain).
