//! Static library for eth-act standards test guests on OpenVM: eth-act/ere's
//! `ere-platform-openvm`, unchanged.
//!
//! OpenVM ships no C library. This archive links:
//! - ere's `zkvm_io.h` functions (`read_input`, `write_output`): the first
//!   `read_input` reads the hint stream and later calls return the same buffer;
//!   `write_output` appends to the public output and reveals the words it
//!   touches, so the output is the concatenation of all writes. ere limits the
//!   output to 256 bytes;
//! - ere's `zkvm_accelerators.h` implementation (`zkvm_*`, on
//!   `openvm-accelerators`);
//! - through ere, the `openvm` guest crate: `_start`/`__start` (which calls the C
//!   `main`), the panic handler, the heap allocator and `openvm-mem`
//!   (`memcpy`, `memmove`, `memset`, `memcmp`, `bcmp`).
#![no_std]

use ere_platform_openvm as _;
