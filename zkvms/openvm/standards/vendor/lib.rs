//! C I/O for eth-act standards test guests on OpenVM, on top of eth-act/ere's `ere-platform-openvm`.
//!
//! OpenVM ships no C library. This archive links, unchanged:
//! - ere's `zkvm_accelerators.h` implementation (`zkvm_*`, on OpenVM guest libraries);
//! - through ere, the `openvm` guest crate: `_start`/`__start` (which calls the C
//!   `main`), the panic handler, the heap allocator and `openvm-mem`
//!   (`memcpy`, `memmove`, `memset`, `memcmp`, `bcmp`).
//!
//! The only code added here is the two `zkvm_io.h` functions, which forward to
//! ere's `OpenVMPlatform` I/O, and `zkvm_random_u64` (`zkvm_random.h`), which
//! forwards to OpenVM's `hint_random`:
//! - `read_input` calls `OpenVMPlatform::read_input` once and keeps the bytes, so
//!   that repeated calls return the same buffer (the hint stream is consumed on read).
//! - `write_output` appends to a buffer and passes the whole buffer to
//!   `OpenVMPlatform::write_output`. That function reveals from byte 0 on each call,
//!   and OpenVM lets a later reveal overwrite an earlier one, so the public output is
//!   the concatenation of all writes. ere limits the output to 256 bytes.
//! - `zkvm_random_u64` reads one hint word after `hint_random(1)`, as OpenVM's
//!   own `sys_rand` does. The host executor chooses the seed.
#![no_std]

extern crate alloc;

use alloc::vec::Vec;
use core::ptr::addr_of_mut;

use ere_platform_openvm::{
    openvm::{hint_buffer_bytes, hint_random, HINT_WORD_BYTES},
    OpenVMPlatform, Platform,
};

static mut INPUT: Option<Vec<u8>> = None;
static mut OUTPUT: Vec<u8> = Vec::new();

/// # Safety
/// `buf_ptr` and `buf_size` must be valid for writes. The guest is single-threaded.
#[no_mangle]
pub unsafe extern "C" fn read_input(buf_ptr: *mut *const u8, buf_size: *mut usize) {
    let input = (*addr_of_mut!(INPUT)).get_or_insert_with(|| OpenVMPlatform::read_input().to_vec());
    *buf_ptr = input.as_ptr();
    *buf_size = input.len();
}

/// # Safety
/// `output` must be valid for `size` bytes of reads. The guest is single-threaded.
#[no_mangle]
pub unsafe extern "C" fn write_output(output: *const u8, size: usize) {
    if size == 0 {
        return;
    }
    let buffer = &mut *addr_of_mut!(OUTPUT);
    buffer.extend_from_slice(core::slice::from_raw_parts(output, size));
    OpenVMPlatform::write_output(buffer);
}

#[no_mangle]
pub extern "C" fn zkvm_random_u64() -> u64 {
    let mut value = 0u64;
    hint_random(1);
    // SAFETY: `value` is writable for `HINT_WORD_BYTES` bytes.
    unsafe { hint_buffer_bytes(&mut value as *mut u64 as *mut u8, HINT_WORD_BYTES) };
    value
}
