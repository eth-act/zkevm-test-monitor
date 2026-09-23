# ZisK platform for act-extra guests. Sourced by extra-tests/build.sh.
#
# The vendor library is ziskos-staticlib built for the standard target
# riscv64im-unknown-none-elf (see Dockerfile). It provides _start, the I/O
# interface, the accelerators and the memory operations. link.ld is ZisK's own
# linker script at the same version.

CC="${CC:-riscv64-unknown-elf-gcc}"
AR="${AR:-riscv64-unknown-elf-ar}"
CFLAGS="-march=rv64im -mabi=lp64 -mcmodel=medany -O2 -std=c11 -ffreestanding -fno-builtin -Wall -Wextra -Werror"
LINKER_SCRIPT="$PLATFORM_DIR/link.ld"
VENDOR_LIB="${VENDOR_LIB:-/opt/zisk/lib/libziskos_staticlib.a}"
LDFLAGS="-nostdlib -nostartfiles -static -Wl,--gc-sections"
LIBS="-lgcc"
