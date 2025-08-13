# Project Overview: ZKEVM Test Monitor

## Purpose

The ZKEVM Test Monitor is a comprehensive testing framework designed to validate Zero-Knowledge Ethereum Virtual Machine (ZKVM) implementations against the RISC-V Architectural Test Suite. This project provides a standardized, containerized environment for differential testing of various ZKVM implementations.

## Core Objectives

1. **Standardized Testing**: Provide a consistent testing environment for ZKVM implementations
2. **Differential Analysis**: Compare ZKVM behavior against reference implementations
3. **Compliance Verification**: Ensure ZKVM implementations adhere to RISC-V architectural specifications
4. **Automated Reporting**: Generate comprehensive test reports and dashboards

## Supported ZKVM Platforms

The project currently includes plugins for the following ZKVM implementations:

- **SP1**: Succinct's zkVM for verifiable computation
- **Jolt**: Lightning-fast SNARKs with Jolt lookups
- **OpenVM**: Modular, performant zkVM framework
- **Spike**: RISC-V ISA simulator (reference implementation)
- **Sail**: Formal specification-based simulator

## Key Components

### Docker Container
- **Base**: Ubuntu 24.04
- **Purpose**: Isolated, reproducible testing environment
- **Includes**: RISC-V toolchain, RISCOF framework, reference models

### Plugin Architecture
- **Modular Design**: Each ZKVM has its own plugin implementation
- **Standardized Interface**: All plugins follow the RISCOF pluginTemplate
- **Configurable**: ISA and platform specifications per ZKVM

### Test Framework
- **RISCOF**: RISC-V Architectural Test Framework
- **Test Suite**: Official RISC-V architectural tests v3.9.1
- **Reference Model**: Sail RISC-V formal specification

## Workflow

1. **Container Setup**: Build Docker image with all dependencies
2. **Plugin Configuration**: Mount ZKVM binary and plugin directory
3. **Dynamic Configuration**: Automatically detect and configure test environment
4. **Test Execution**: Run differential tests against reference model
5. **Report Generation**: Produce HTML reports with pass/fail results

## Target Users

- **ZKVM Developers**: Validate implementations against specifications
- **Security Researchers**: Analyze ZKVM behavior and compliance
- **Integration Teams**: Ensure compatibility across different ZKVMs
- **Quality Assurance**: Systematic testing of ZKVM releases

## Benefits

- **Standardization**: Consistent testing methodology across implementations
- **Automation**: Minimal manual configuration required
- **Portability**: Containerized environment works across platforms
- **Scalability**: Parallel test execution for performance
- **Transparency**: Clear reporting of test results and failures