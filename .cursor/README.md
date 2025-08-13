# AI Documentation for ZKEVM Test Monitor

This directory contains comprehensive documentation about the ZKEVM Test Monitor project, designed to help AI assistants and developers understand the codebase structure, architecture, and implementation details.

## Documentation Files

- `project_overview.md` - High-level project description and goals
- `architecture.md` - System architecture and component relationships
- `plugins/` - Detailed documentation for each ZKVM plugin
- `docker_setup.md` - Docker container configuration and usage
- `testing_framework.md` - RISCOF testing framework integration
- `development_guide.md` - Development workflows and best practices

## Purpose

This project provides a Docker-based testing environment for Zero-Knowledge Ethereum Virtual Machines (ZKEVMs) using the RISC-V Architectural Tests through the RISCOF framework. It enables differential testing between various ZKVM implementations and a reference model.

## Quick Reference

- **Main Entry Point**: `entrypoint.sh` - Dynamic configuration script
- **Plugin Directory**: `plugins/` - Contains ZKVM-specific test plugins
- **Test Results**: `results/` - Generated test reports and artifacts
- **Docker Image**: Built from `Dockerfile` with Ubuntu 24.04 base