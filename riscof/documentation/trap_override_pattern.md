# RISCOF Trap Handler Override Pattern

## Overview

This document describes the `extra_trap_routine` pattern that enables differential testing of trap handling between RISC-V models with and without CSR support. A single test file can run on both CSR-based implementations (like Sail) and non-CSR implementations (like zkVMs).

## The Problem

Traditional RISC-V trap handling tests use the `rvtest_mtrap_routine` macro which requires CSR instructions (mtvec, mscratch, etc.). Many zkVM implementations don't support CSRs, making it impossible to run standard trap tests on them.

## The Solution: extra_trap_routine

The `extra_trap_routine` macro serves as a plugin-agnostic trap handling directive. When a test defines `def extra_trap_routine=True`, each plugin interprets it according to its capabilities:

- **CSR-capable models (Sail)**: Map to standard `rvtest_mtrap_routine` with Zicsr
- **Non-CSR models (zkVMs)**: Implement custom trap handling in `model_test.h`

## Implementation Guide

### For Test Writers

In your test file (e.g., `ecall-01.S`):

```assembly
RVTEST_CASE(1,"//check ISA:=regex(.*64.*); def extra_trap_routine=True",ecall)

# Test code with ecall instruction
ecall

# Data section with trap signature region
#ifdef extra_trap_routine
mtrap_sigptr:
  .fill 8, 4, 0xdeadbeef
#endif
```

### For Plugin Developers

#### Step 1: Detect extra_trap_routine in Compilation

In your plugin's `riscof_<plugin>.py`:

```python
def runTests(self, testList):
    for testname in testList:
        compile_macros = ' -D' + " -D".join(testentry['macros'])
        march = testentry['isa'].lower()

        if 'extra_trap_routine=True' in compile_macros:
            # Handle based on your architecture
            # See examples below
```

#### Step 2: Choose Your Implementation Strategy

##### Option A: Models WITH CSR Support (e.g., Sail)

Map `extra_trap_routine` to standard CSR-based handling:

```python
if 'extra_trap_routine=True' in macros:
    # Convert to standard CSR-based traps
    if '_zicsr' not in march:
        march = march + '_zicsr'
    # Map extra_trap_routine to rvtest_mtrap_routine
    macros = [m.replace('extra_trap_routine=True',
                       'rvtest_mtrap_routine=True') for m in macros]
```

##### Option B: Models WITHOUT CSR Support (e.g., zkVMs)

Implement custom trap handling in `model_test.h`:

```assembly
#ifdef extra_trap_routine

.macro EXTRA_TRAP_HANDLER
    // Your custom trap mechanism
    // Examples:
    // - Write to memory-mapped registers
    // - Use special termination instruction
    // - Set specific register values
    // No CSR operations needed!
.endm

EXTRA_TRAP_HANDLER

#endif // extra_trap_routine
```

## Example Implementations

### Memory-Mapped Trap Handler

```assembly
#ifdef extra_trap_routine
.macro HANDLE_ECALL
    // Write trap info to memory-mapped region
    li t0, 0x80000000      // Trap handler address
    li t1, 11              // ECALL trap code
    sw t1, 0(t0)           // Write trap code
    // Continue execution or terminate
.endm
#endif
```

### ECALL-Based Termination

```assembly
#ifdef extra_trap_routine
.macro HANDLE_ECALL
    // Use specific register values to indicate trap
    li x10, 0              // Success code
    li x11, 11             // ECALL identifier
    // Custom termination sequence
    .word 0x00000073       // ecall (will terminate in zkVM)
.endm
#endif
```

### Infinite Loop Pattern

```assembly
#ifdef extra_trap_routine
.macro HANDLE_ECALL
    // Some zkVMs use infinite loop for completion
    trap_loop:
    j trap_loop
.endm
#endif
```

## Testing Your Implementation

1. **Create a test** with `def extra_trap_routine=True`
2. **Run on reference model** (Sail with CSRs)
3. **Run on your model** (with custom handling)
4. **Compare signatures** to validate behavior

## Benefits

- **Single test file** runs on diverse architectures
- **No macro conflicts** with standard framework
- **Clean separation** of CSR and non-CSR implementations
- **Extensible pattern** for future trap-related testing

## Files Modified in This Pattern

- Test files: Use `extra_trap_routine` instead of `rvtest_mtrap_routine`
- Plugin Python files: Detect and handle `extra_trap_routine`
- Plugin model_test.h: Implement custom trap handlers
- No changes needed to arch_test.h or RISCOF core

## Migration Guide

To convert existing trap tests:

1. Replace `def rvtest_mtrap_routine=True` with `def extra_trap_routine=True`
2. Update `#ifdef rvtest_mtrap_routine` to `#ifdef extra_trap_routine`
3. Ensure plugins handle the new macro appropriately

## Future Extensions

The `extra_` prefix can be used for other ACT-Extra specific behaviors that differ from standard RISC-V arch tests:

- `extra_interrupt_routine` for interrupt handling
- `extra_debug_routine` for debug mode testing
- `extra_privilege_routine` for privilege transition testing

Each would follow the same pattern: plugins interpret the macro according to their capabilities.