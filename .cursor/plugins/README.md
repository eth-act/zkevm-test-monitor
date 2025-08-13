# Plugin Documentation

This directory contains detailed documentation for each ZKVM plugin implementation in the test monitor.

## Available Plugins

- `sp1.md` - SP1 zkVM plugin documentation
- `jolt.md` - Jolt zkVM plugin documentation  
- `openvm.md` - OpenVM plugin documentation
- `spike.md` - Spike reference simulator plugin
- `sail_cSim.md` - Sail reference model plugin

## Plugin Structure

Each plugin follows the RISCOF plugin template and provides:

1. **Main Plugin Class**: Implements the core testing logic
2. **ISA Specification**: Defines supported RISC-V extensions
3. **Platform Specification**: Platform-specific configurations
4. **Environment Files**: Compilation and linking setup

## Common Functionality

All plugins implement the standard RISCOF interface:
- Test compilation using RISC-V toolchain
- Signature extraction for differential testing
- Parallel test execution
- Result reporting

## Plugin Development

For creating new plugins, refer to the existing implementations as templates and ensure compliance with the RISCOF plugin interface.