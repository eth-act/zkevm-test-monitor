# Breakage Snippets

One-liners to inject an ADD off-by-one bug into each ZKVM executor, for verifying the
test harness catches arithmetic errors. Each breaks register-register ADD (result += 1)
while leaving ADDI intact where possible.

Revert any of these with `git restore <file>` in the relevant symlinked repo.

---

## OpenVM

Breaks all reg-reg ALU ops (ADD, SUB, XOR, OR, AND) — not just ADD — because OpenVM
folds ADDI into the same ADD opcode but dispatches via a `IS_IMM` const generic.

**Break:**
```bash
sed -i 's/let rd = <OP as AluOp>::compute(rs1, rs2);/let rd = <OP as AluOp>::compute(rs1, rs2).wrapping_add(if IS_IMM { 0 } else { 1 });/' \
    openvm/extensions/rv32im/circuit/src/base_alu/execution.rs
```

**Build + test:**
```bash
cd docker/build-openvm/openvm-elf-runner && cargo build --release && cd - && cp docker/build-openvm/openvm-elf-runner/target/release/openvm-binary binaries/ && ./run test openvm
```

**Revert:**
```bash
cd openvm && git restore extensions/rv32im/circuit/src/base_alu/execution.rs && cd -
```

---

## r0vm

Breaks only register-register ADD. ADDI is a separate match arm (`InsnKind::Addi`) so
it is unaffected.

**Break:**
```bash
sed -i 's/InsnKind::Add => rs1.wrapping_add(rs2),/InsnKind::Add => rs1.wrapping_add(rs2).wrapping_add(1),/' \
    risc0/risc0/circuit/rv32im/src/execute/rv32im.rs
```

**Build + test:**
```bash
cd risc0 && cargo build --release -p risc0-r0vm --bin r0vm && cd - && cp risc0/target/release/r0vm binaries/r0vm-binary && ./run test r0vm
```

**Revert:**
```bash
cd risc0 && git restore risc0/circuit/rv32im/src/execute/rv32im.rs && cd -
```

---

## Pico

Breaks only register-register ADD. Pico folds ADDI into `Opcode::ADD` but the
`Instruction` struct carries `imm_c: bool`, so we can distinguish at runtime.
Two files must be patched (full emulator + simple/preflight emulator).

**Break:**
```bash
sed -i 's/a = b.wrapping_add(c);/a = b.wrapping_add(c).wrapping_add(if instruction.imm_c { 0 } else { 1 });/' \
    pico/vm/src/emulator/riscv/emulator/instruction.rs \
    pico/vm/src/emulator/riscv/emulator/instruction_simple.rs
```

**Build + test:**
```bash
cd pico && cargo build --release -p pico-cli && cd - && cp pico/target/release/cargo-pico binaries/pico-binary && ./run test pico
```

**Revert:**
```bash
cd pico && git restore vm/src/emulator/riscv/emulator/instruction.rs vm/src/emulator/riscv/emulator/instruction_simple.rs && cd -
```

---

## SP1

Breaks only register-register ADD. SP1 folds ADDI into `Opcode::ADD` but `imm_c`
distinguishes them. The executor branch is `act4-perf-executor` (not main) — make sure
`sp1/` is on that branch before building.

Expected result: **44/47 native** (3 ADD tests fail). The target suite (rv64im-zicclsm)
is 0/72 regardless — pre-existing issue unrelated to this patch.

**Break:**
```bash
sed -i 's/Opcode::ADD => b.wrapping_add(c),/Opcode::ADD => b.wrapping_add(c).wrapping_add(if instruction.imm_c { 0 } else { 1 }),/' \
    sp1/crates/core/executor/src/executor.rs
```

**Build + test:**
```bash
cd sp1 && cargo build --bin sp1-perf-executor && cd - && cp sp1/target/debug/sp1-perf-executor binaries/sp1-binary && ./run test sp1
```

**Revert:**
```bash
cd sp1 && git restore crates/core/executor/src/executor.rs && cd -
```
