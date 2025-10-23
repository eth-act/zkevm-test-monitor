# OpenVM RISCOF Plugin Environment

This directory contains environment files for running RISC-V architecture tests with OpenVM.

## Build Artifacts

The following files are **build artifacts** (not tracked in git):
- `*.o` - Compiled object files
- `*.a` - Static libraries

These are automatically built by `build_float_lib.sh` when needed.

## Rebuilding Float Library

To rebuild the float library artifacts:

```bash
./build_float_lib.sh
```

This script:
1. Compiles `float.o` from the Zisk float handler source
2. Compiles `compiler_builtins.o` for RV32 support
3. Builds `libziskfloat.a` from SoftFloat-3e sources

All artifacts are compiled from source code defined in the OpenVM repository:
- Float handler: `extensions/floats/guest/vendor/zisk/lib-float/c/src/float/`
- SoftFloat library: `extensions/floats/guest/vendor/zisk/lib-float/c/SoftFloat-3e/`
- Compiler builtins: `extensions/floats/guest/vendor/compiler_builtins.c`

## Files

### Source Files (tracked in git)
- `link.ld` - Linker script for RISCOF tests
- `float_init.S` - Runtime initialization for float library
- `model_test.h` - Test framework macros
- `build_float_lib.sh` - Script to build float library artifacts

### Build Artifacts (not tracked)
- `float.o` - Main float handler (built from Zisk sources)
- `compiler_builtins.o` - Compiler runtime support for RV32
- `libziskfloat.a` - SoftFloat library

## Integration

The RISCOF plugin (`riscof_openvm.py`) automatically links these files when compiling float tests (rv32imf).

### Error Handling

If the build artifacts are missing when running RISCOF tests, the plugin will:
1. Detect which files are missing
2. Display a clear error message with the missing file paths
3. Provide instructions on how to build them
4. Exit with an error code to prevent compilation failures

Example error:
```
ERROR | Float extension enabled but required files are missing:
ERROR |   - /riscof/plugins/openvm/env/float.o
ERROR |
ERROR | To build the float library, run:
ERROR |   /riscof/plugins/openvm/env/build_float_lib.sh
```

### Automatic Building

The `riscof_build_run.sh` script in the repo root automatically runs `build_float_lib.sh` if the artifacts are missing, so you typically don't need to build them manually.
