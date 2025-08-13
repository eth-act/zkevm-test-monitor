# SP1 Plugin Environment Configuration

## Overview
This directory contains environment configuration files for the SP1 (Succinct Prover) RISCV-V zero-knowledge virtual machine plugin used with the RISCOF testing framework.

## Purpose
The SP1 plugin enables testing of the SP1 ZKVM implementation against the official RISC-V Architectural Test Suite to verify compliance with RISC-V specifications.

## Component Structure

### Files
- **`link.ld`** - Linker script for SP1 test compilation
- **`model_test.h`** - C preprocessor macros and definitions for RISCOF test integration

## Technical Details

### link.ld
- **Location**: `plugins/sp1/env/link.ld:1-18`
- **Purpose**: Defines memory layout for compiled RISC-V test binaries
- **Key Sections**:
  - Text initialization at `0x20000000`
  - TOHOST communication section for signature extraction
  - Aligned text, data, and BSS sections

### model_test.h
- **Location**: `plugins/sp1/env/model_test.h:1-79`
- **Purpose**: RISCOF integration macros for SP1 ZKVM
- **Key Features**:
  - 32-bit RISC-V configuration (`__riscv_xlen 32`)
  - Custom halt logic using `ecall` with SP1-specific parameters
  - Signature extraction support for differential testing
  - Test pass/fail mechanisms

## Integration
This environment configuration works with:
- **Parent Plugin**: `../riscof_sp1.py` - Main SP1 plugin implementation
- **ISA Specification**: `../sp1_isa.yaml` - RV32IM instruction set definition
- **Platform Specification**: `../sp1_platform.yaml` - Platform-specific configuration

## Usage Context
These files are automatically used during RISCOF test compilation and execution when testing SP1 ZKVM compliance with RISC-V architectural tests. The linker script ensures proper memory layout while the header file provides the necessary runtime environment for signature-based differential testing.