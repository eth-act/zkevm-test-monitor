# OpenVM platform for act-extra guests. Sourced by extra-tests/build.sh.
#
# OpenVM ships no C library. The library here is libere_openvm_c.a, built from
# eth-act/ere's ere-platform-openvm plus a thin I/O wrapper (vendor/lib.rs, see
# Dockerfile). It provides _start, the I/O interface, the accelerators and
# OpenVM's memory operations. OpenVM guests use no linker script: the linker's
# default layout with the text at 0x00200800 (openvm-build and ere's compiler
# pass -Ttext=0x00200800).

OPENVM_LIB_DIR="${OPENVM_LIB_DIR:-/opt/openvm/lib}"
CC="${CC:-clang}"
AR="${AR:-llvm-ar}"
CFLAGS="--target=riscv64-unknown-none-elf -march=rv64im -mabi=lp64 -mcmodel=medany -O2 -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -nostdlibinc -Wall -Wextra -Werror"
LINKER_SCRIPT=""
VENDOR_LIB="${VENDOR_LIB:-$OPENVM_LIB_DIR/libere_openvm_c.a}"
LDFLAGS="-fuse-ld=lld -nostdlib -static -Wl,--gc-sections -Wl,-Ttext=0x00200800"
LIBS=""
