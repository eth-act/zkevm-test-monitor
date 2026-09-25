# SP1 platform for eth-act standards test guests. Sourced by eth-act-standards-tests/build-guests.sh.
#
# The vendor library is libzkevm.a from SP1's zkEVM SDK (`make sdk` in
# zkevm/, see Dockerfile). It provides _start, the I/O interface and the
# accelerators. The flags follow the SDK README: clang for
# riscv64-unknown-none-elf (sp1_build::CLANG_FLAGS), ld.lld and the SDK's
# own zkvm.ld.

SP1_SDK="${SP1_SDK:-/opt/sp1}"
CC="${CC:-clang}"
AR="${AR:-llvm-ar}"
CFLAGS="--target=riscv64-unknown-none-elf -march=rv64im -mabi=lp64 -mcmodel=medany -O2 -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -nostdlibinc -Wall -Wextra -Werror"
LINKER_SCRIPT="$SP1_SDK/zkvm.ld"
VENDOR_LIB="${VENDOR_LIB:-$SP1_SDK/libzkevm.a}"
LDFLAGS="-fuse-ld=lld -nostdlib -static -Wl,--gc-sections"
LIBS=""
