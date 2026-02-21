# Hack Tracking

Status of workarounds applied to make ACT4 tests run on ZK-VMs.

---

## Not Hacks (correct DUT integration)

Changes in `riscv-arch-test/config/<zkvm>/` are using ACT4's designed extension points.

| File | Change | Status |
|------|--------|--------|
| SP1/Pico/OpenVM `rvmodel_macros.h` | Halt macros (correct syscall reg / custom opcodes) | Clean |
| Zisk `rvmodel_macros.h` | Halt convention, MSW_INT macros | Clean |
| Zisk `link.ld` | Move data to `0xa0010000` (Zisk's RAM region) | Clean |
| Zisk entrypoint | RAM-based parallelism scaling (OOM fix) | Clean |

---

## Resolved Hacks

### ~~Hack 1~~ — CSR instructions in test preamble ✅ RESOLVED

**Root cause**: SP1/Pico/OpenVM UDB configs declared `Sm` (machine-mode spec) and
`Zicsr`. ACT4's test generator (`generators/testgen/src/testgen/io/templates.py`)
defines `#define rvtest_mtrap_routine` whenever `Sm` is in the extension list, which
causes `RVTEST_INIT_REGS` to emit `csrw mstatus/mepc/mip/mtval/mcause`. SP1/Pico treat
ALL opcode-0x73 as ecalls and panic.

**Fix applied**: Removed `Sm` and `Zicsr` from `implemented_extensions` in all six
affected UDB configs (sp1/pico/openvm × rv32im/rv64im-zicclsm). Params retained as-is
since `parse_udb_config.py` reads them directly from the YAML without schema
enforcement. The generator no longer defines `rvtest_mtrap_routine`, so no CSR
instructions appear in the test preamble.

**Files changed**:
- `riscv-arch-test/config/sp1/sp1-rv32im/sp1-rv32im.yaml`
- `riscv-arch-test/config/sp1/sp1-rv64im-zicclsm/sp1-rv64im-zicclsm.yaml`
- `riscv-arch-test/config/pico/pico-rv32im/pico-rv32im.yaml`
- `riscv-arch-test/config/pico/pico-rv64im-zicclsm/pico-rv64im-zicclsm.yaml`
- `riscv-arch-test/config/openvm/openvm-rv32im/openvm-rv32im.yaml`
- `riscv-arch-test/config/openvm/openvm-rv64im-zicclsm/openvm-rv64im-zicclsm.yaml`

---

### ~~Hack 3~~ — EF_RISCV_RVC ELF header flag ✅ RESOLVED

**Root cause**: `test_setup.h` used `.option rvc` / `.align UNROLLSZ` / `.option norvc`
as an alignment trick, causing GAS to set the `EF_RISCV_RVC` flag in the ELF header
even though no compressed instructions are emitted. SP1/Pico/OpenVM reject ELFs with
this flag.

**Fix applied**: Removed `.option rvc` from the alignment block in `RVTEST_BEGIN`
(line 31 of `test_setup.h`). The `.option norelax` (already present two lines earlier)
supersedes the purpose of this trick. Replaced with explicit `.option norvc` +
`.align UNROLLSZ`.

**Files changed**:
- `riscv-arch-test/tests/env/test_setup.h`

---

## Active Workarounds

### Hack 2 — `.word` data embedded in `.text`

**Status**: Active workaround — upstream ACT4 fix needed.

**Root cause**: ACT4's SELFCHECK mechanism uses a return-address thunk pattern. After
each `jal x5, failedtest_handler`, the next 4 bytes are a `.word` pointer to the
test-name string (placed inline in `.text`). The failure handler reads
`LREG x6, 0(DEFAULT_LINK_REG)` to load it. SP1/Pico/OpenVM pre-process ALL 32-bit
words in executable segments as instructions before execution, panicking on these
arbitrary pointer values.

**Current workaround**: `docker/shared/patch_elfs.py` uses `riscv64-unknown-elf-objdump`
to identify `.word` entries in executable sections and replaces them with NOPs
(`addi x0, x0, 0 = 0x00000013`). Safe because:
- The `.word` is after an unconditional `jal` — never executed.
- Only read by the failure handler for diagnostic output.
- `RVMODEL_IO_WRITE_STR` is a no-op for these ZKVMs — losing the string is harmless.

**Upstream fix**: Move SELFCHECK string pointers from inline `.text` to `.rodata`, use
PC-relative load. This would remove the need for `patch_elfs.py` entirely.

**File**: `docker/shared/patch_elfs.py` (single copy, used by SP1/Pico/OpenVM containers)

---

## Summary Table

| Issue | Root cause | Current status | File(s) |
|-------|-----------|----------------|---------|
| CSR instructions in test preamble | UDB config declared Sm/Zicsr | ✅ Resolved — config fix | 6 UDB yamls |
| `.word` data in `.text` | ACT4 SELFCHECK thunk | ⚠️ Active workaround | `docker/shared/patch_elfs.py` |
| EF_RISCV_RVC ELF flag | `.option rvc` alignment trick | ✅ Resolved — test_setup.h fix | `tests/env/test_setup.h` |
| Zisk linker script | Zisk RAM at 0xa0000000 | Clean — correct approach | `zisk-rv64im/link.ld` |
| SP1/Pico syscall register | SP1/Pico use t0, not a7 | Clean — correct approach | `rvmodel_macros.h` |
