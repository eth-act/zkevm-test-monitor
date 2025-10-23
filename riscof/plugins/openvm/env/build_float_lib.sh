#!/bin/bash
set -e

# This script must be run from the openvm repository root or zkevm-test-monitor directory
if [ -d "extensions/floats" ]; then
    # We're in openvm root
    OPENVM_ROOT="$(pwd)"
elif [ -d "../extensions/floats" ]; then
    # We're in zkevm-test-monitor
    OPENVM_ROOT="$(cd .. && pwd)"
elif [ -d "../../extensions/floats" ]; then
    # We're in riscof/
    OPENVM_ROOT="$(cd ../.. && pwd)"
else
    # Try to find it relative to script location
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Go up from riscof/plugins/openvm/env/ -> ../../../../../
    OPENVM_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
    if [ ! -d "$OPENVM_ROOT/extensions/floats" ]; then
        echo "Error: Could not find OpenVM repository root"
        echo "Please run this script from the openvm repository directory"
        exit 1
    fi
fi

FLOAT_LIB_DIR="$OPENVM_ROOT/extensions/floats/guest/vendor/zisk/lib-float/c"
SOFTFLOAT_SRC="$FLOAT_LIB_DIR/SoftFloat-3e/source"
SOFTFLOAT_8086="$SOFTFLOAT_SRC/8086"

# Output directory - always in zkevm-test-monitor/riscof/plugins/openvm/env/
OUT_DIR="$OPENVM_ROOT/zkevm-test-monitor/riscof/plugins/openvm/env"

echo "Building float library for RISCOF tests..."

# Compiler flags for rv32imf
CFLAGS="-march=rv32imf -mabi=ilp32f -ffreestanding -nostdlib -mcmodel=medany -O3 -DZISK_GCC"
CFLAGS="$CFLAGS -I$SOFTFLOAT_SRC/include -I$SOFTFLOAT_8086 -I$FLOAT_LIB_DIR/src/float"

# Compile the main float handler
echo "Compiling float.c..."
riscv64-elf-gcc $CFLAGS -c "$FLOAT_LIB_DIR/src/float/float.c" -o "$OUT_DIR/float.o"

# Compile compiler_builtins (provides __ucmpdi2 for rv32)
echo "Compiling compiler_builtins.c..."
COMPILER_BUILTINS="$OPENVM_ROOT/extensions/floats/guest/vendor/compiler_builtins.c"
riscv64-elf-gcc $CFLAGS -c "$COMPILER_BUILTINS" -o "$OUT_DIR/compiler_builtins.o"

# Check if libziskfloat.a already exists
PREBUILT_LIB="$FLOAT_LIB_DIR/lib/libziskfloat.a"
if [ -f "$PREBUILT_LIB" ]; then
    echo "Using prebuilt libziskfloat.a from $PREBUILT_LIB"
    cp "$PREBUILT_LIB" "$OUT_DIR/libziskfloat.a"
else
    echo "Error: Prebuilt libziskfloat.a not found at $PREBUILT_LIB"
    echo "Please build the float library first by running the examples/floats/build.sh script"
    exit 1
fi

echo "✅ Float library build complete:"
ls -lh "$OUT_DIR"/*.o "$OUT_DIR"/*.a
