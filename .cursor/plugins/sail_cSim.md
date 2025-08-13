# Sail RISC-V Plugin Documentation

## Overview

The Sail RISC-V plugin integrates the formal specification-based RISC-V simulator into the RISCOF testing framework. Sail RISC-V is the official golden reference model based on the formal RISC-V specification written in the Sail architecture description language.

## Plugin Implementation

### File: `plugins/sail_cSim/riscof_sail_cSim.py`

**Class**: `sail_cSim(pluginTemplate)`
**Model**: "sail_cSim"
**Purpose**: Formal specification reference implementation

### Key Features

- **Formal Specification**: Based on official RISC-V formal specification
- **Golden Reference**: Authoritative reference for RISC-V behavior
- **Comprehensive Coverage**: Complete ISA implementation
- **Specification Compliance**: Direct translation from formal specification

## Sail Architecture Description Language

### What is Sail?
Sail is a domain-specific language for describing processor architectures:
- **Formal Semantics**: Mathematical precision in instruction definition
- **Executable Specification**: Can be compiled to working simulators
- **Multiple Backends**: Generate C, OCaml, Coq, and other implementations
- **Verification Ready**: Supports formal verification workflows

### RISC-V Specification in Sail
The RISC-V Sail specification includes:
```sail
/* Example: ADD instruction definition */
function clause execute(RTYPE(rs2, rs1, rd, RISCV_ADD)) = {
  let rs1_val = X(rs1);
  let rs2_val = X(rs2);
  let result = rs1_val + rs2_val;
  X(rd) = result;
  RETIRE_SUCCESS
}
```

## Configuration

### ISA Specification
The Sail model supports the complete RISC-V specification:
```yaml
hart_ids: [0]
hart0:
  ISA: RV32IMAFDC_Zicsr_Zifencei  # Complete base ISA
  physical_addr_sz: 32
  User_Spec_Version: '2.3'
  Machine_Spec_Version: '1.11'
  supported_xlen: [32, 64]
  
  # Comprehensive privilege level support
  privilege_modes:
    - M  # Machine mode
    - S  # Supervisor mode  
    - U  # User mode
```

### Platform Specification
- **Memory Model**: Complete RISC-V memory model implementation
- **CSR Registers**: All control and status registers
- **Interrupt Handling**: Complete interrupt and exception handling
- **MMU Support**: Full memory management unit implementation

## Implementation Details

### Compilation from Sail
The Sail specification is compiled to C:
```bash
# Sail to C compilation
sail -c -o riscv_sim riscv.sail
gcc -O2 riscv_sim.c -o riscv_sim
```

### Execution Model
```python
class sail_cSim(pluginTemplate):
    def __init__(self, config):
        # Sail simulator configuration
        self.sail_exe = config.get('PATH') + '/riscv_sim_RV32'
    
    def runTests(self, testList):
        # Execute using Sail simulator
        for test in testList:
            cmd = f'{self.sail_exe} --test-signature={sig_file} {elf}'
            self._execute_command(cmd)
```

### Signature Generation
Sail RISC-V provides precise signature extraction:
```c
// Signature region in Sail
#define SIGNATURE_START 0x80000000
#define SIGNATURE_END   0x80001000

// Automatic signature capture
void write_tohost(uint64_t data) {
    // Sail captures all memory writes in signature region
    *(volatile uint64_t*)SIGNATURE_START = data;
}
```

## Formal Specification Features

### Instruction Semantics
Each instruction is formally defined:
```sail
/* Integer arithmetic with formal semantics */
function clause execute(RTYPE(rs2, rs1, rd, op)) = {
  let rs1_val : xlenbits = X(rs1);
  let rs2_val : xlenbits = X(rs2);
  let result : xlenbits = match op {
    RISCV_ADD  => rs1_val + rs2_val,
    RISCV_SUB  => rs1_val - rs2_val,
    RISCV_AND  => rs1_val & rs2_val,
    RISCV_OR   => rs1_val | rs2_val,
    RISCV_XOR  => rs1_val ^ rs2_val,
    /* ... */
  };
  X(rd) = result;
  RETIRE_SUCCESS
}
```

### Memory Model
Complete RISC-V memory model implementation:
```sail
/* Memory access with formal semantics */
function mem_read(addr : xlenbits, width : word_width) -> MemoryOpResult(bits(8 * width)) = {
  /* Check alignment */
  if not(is_aligned(addr, width)) then MemException(E_Load_Addr_Align())
  /* Check permissions */
  else if not(is_readable(addr)) then MemException(E_Load_Access_Fault())
  /* Perform read */
  else MemValue(read_mem(addr, width))
}
```

### Privilege Architecture
Complete privilege level implementation:
```sail
/* Privilege mode transitions */
function handle_exception(cause : ExceptionType) -> unit = {
  let current_priv = cur_privilege;
  let target_priv = exception_delegated(cause, current_priv);
  
  /* Update privilege state */
  mstatus = update_mstatus_on_exception(mstatus, current_priv);
  mcause = exception_cause(cause);
  mepc = get_next_pc();
  
  /* Transfer to handler */
  cur_privilege = target_priv;
  set_next_pc(exception_handler_address(cause, target_priv));
}
```

## Formal Verification Integration

### Theorem Proving
Sail specifications can be translated to theorem provers:
```coq
(* Coq translation for formal verification *)
Definition execute_add (rs1 rs2 rd : regidx) : M unit :=
  rs1_val <- read_reg rs1 ;;
  rs2_val <- read_reg rs2 ;;
  let result := add rs1_val rs2_val in
  write_reg rd result.
```

### Property Verification
Formal properties can be verified:
```sail
/* Safety property: No register corruption */
$property no_register_corruption(old_state, new_state) = {
  forall r. r != rd ==> X_old(r) == X_new(r)
}
```

### Equivalence Checking
Compare implementations for equivalence:
```sail
/* Specification equivalence */
$prove forall rs1 rs2 rd.
  execute_add_spec(rs1, rs2, rd) <==> execute_add_impl(rs1, rs2, rd)
```

## Configuration and Usage

### Compilation Options
```bash
# Different target architectures
sail -c -arch rv32 -o riscv_sim_RV32 model/riscv_model_RV32.sail
sail -c -arch rv64 -o riscv_sim_RV64 model/riscv_model_RV64.sail

# Debug builds with trace
sail -c -trace -o riscv_sim_debug model/riscv_model.sail
```

### Execution Modes
```bash
# Basic execution
./riscv_sim_RV32 program.elf

# With signature generation
./riscv_sim_RV32 --test-signature=sig.txt program.elf

# Verbose execution with trace
./riscv_sim_RV32 --trace --trace-file=trace.log program.elf
```

### RISCOF Integration
```python
def runTests(self, testList):
    for testname in testList:
        testentry = testList[testname]
        test_dir = testentry['work_dir']
        elf = 'my.elf'
        sig_file = os.path.join(test_dir, 'DUT-sail_cSim.signature')
        
        # Sail command with signature extraction
        cmd = f'{self.sail_exe} --test-signature={sig_file} {elf}'
        
        # Execute with error handling
        result = subprocess.run(cmd, shell=True, capture_output=True)
        if result.returncode != 0:
            logger.error(f"Sail execution failed: {result.stderr}")
```

## Debugging and Analysis

### Trace Generation
```bash
# Generate instruction trace
./riscv_sim_RV32 --trace --trace-file=instruction_trace.log program.elf

# Memory access trace
./riscv_sim_RV32 --trace-memory --trace-file=memory_trace.log program.elf

# Register state trace
./riscv_sim_RV32 --trace-registers --trace-file=register_trace.log program.elf
```

### Trace Analysis
```python
def analyze_sail_trace(trace_file):
    """Analyze Sail execution trace for debugging."""
    with open(trace_file, 'r') as f:
        for line in f:
            if 'RETIRE' in line:
                # Instruction retirement
                pc, instruction = parse_retire_line(line)
                print(f"PC: 0x{pc:08x}, Instr: {instruction}")
            elif 'MEM' in line:
                # Memory access
                addr, data, access_type = parse_memory_line(line)
                print(f"Memory {access_type}: 0x{addr:08x} = 0x{data:08x}")
```

### Formal Debugging
```sail
/* Debug assertions in Sail */
function debug_check_invariant() -> unit = {
  /* Check architectural invariants */
  assert(mstatus.MIE -> cur_privilege != Machine);
  assert(valid_pc(PC));
  assert(forall r. valid_register_value(X(r)));
}
```

## Performance Characteristics

### Execution Speed
- **Formal Overhead**: Slower than optimized simulators
- **Precision**: Cycle-accurate formal semantics
- **Verification**: Optimized for correctness over speed

### Resource Usage
- **Memory**: Proportional to architectural state
- **CPU**: Single-threaded formal execution
- **I/O**: Comprehensive trace generation

## Integration Benefits

### Reference Authority
- **Specification Compliance**: Direct from formal specification
- **Authoritative Behavior**: Defines correct RISC-V behavior
- **Verification Target**: Golden model for other implementations

### Test Development
- **Test Validation**: Validate test correctness against specification
- **Expected Results**: Generate reference signatures
- **Corner Cases**: Formal specification handles edge cases

### Quality Assurance
- **Compliance Testing**: Verify ISA compliance
- **Regression Testing**: Detect specification violations
- **Formal Verification**: Support formal verification workflows

## Future Development

### Specification Updates
- **ISA Evolution**: Track RISC-V specification updates
- **Extension Support**: New instruction set extensions
- **Formal Methods**: Advanced formal verification techniques

### Tool Integration
- **Verification Tools**: Integration with formal verification tools
- **Debug Support**: Enhanced debugging capabilities
- **Performance**: Optimization while maintaining formal semantics

### Community Contribution
- **Specification Development**: Contribute to RISC-V specification
- **Tool Ecosystem**: Enhance Sail toolchain
- **Verification Methods**: Advance formal verification techniques