# SAIL C Simulator Environment Component

## Overview
This component provides the environment configuration and compilation setup for the SAIL C Simulator plugin within the ZKEVM test monitoring framework. It's part of a RISCOF (RISC-V Architectural Tests) testing system that validates RISC-V implementations against the formal Sail reference model.

## Purpose
The `plugins/sail_cSim/env/` directory contains essential environment files that configure how RISC-V architectural tests are compiled and executed for the SAIL C simulator. This setup enables differential testing between the Sail reference implementation and zero-knowledge virtual machines (ZKVMs).

## Key Files

### link.ld
**Location**: `plugins/sail_cSim/env/link.ld:1-19`
- Linker script defining memory layout for RISC-V test executables
- Sets entry point at `rvtest_entry_point` 
- Defines memory sections starting at address `0x80000000`
- Organizes code (.text), data (.data), and BSS sections with proper alignment
- Includes special `.tohost` section for host communication

### model_test.h  
**Location**: `plugins/sail_cSim/env/model_test.h:1-58`
- C preprocessor macros defining the compliance model interface
- Implements RISCOF test framework requirements including:
  - Data section setup with `tohost`/`fromhost` communication
  - Test halt mechanism via memory-mapped writes
  - Signature begin/end markers for test result extraction
  - PMP (Physical Memory Protection) configuration
  - Empty implementations for I/O operations (simulator-specific)

## Integration
This environment is used by the main SAIL C Simulator plugin (`riscof_sail_cSim.py:48-49`) during the compilation phase:
- Linker script is referenced in compilation commands
- Header file provides necessary macros for test execution
- Both files ensure compatibility with the RISCOF testing framework

## Architecture Support
The environment supports both RV32 and RV64 RISC-V architectures with configurable ISA extensions (I, M, C, F, D) as determined by the parent plugin configuration.

## Testing Context
Part of a larger system that runs differential testing between:
- Sail reference model (REF)
- Zero-knowledge virtual machines as devices under test (DUT)
- Results are compared via signature extraction to validate RISC-V compliance