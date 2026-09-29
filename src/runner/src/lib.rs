//! Host-side test runner for RISC-V zkVMs.
//!
//! One binary, `runner`, runs both suites:
//! - the ACT4 ISA tests (pass = clean exit, optionally prove and verify);
//! - the eth-act standards tests, which check the guest's public output
//!   against its I/O test vectors.
//!
//! Every backend reads the optional per-ELF files `<stem>.input`,
//! `<stem>.expected` and `<stem>.outcome` (see `test_io_and_outcome`).

pub mod backends;
pub mod test_io_and_outcome;
pub mod results;
pub mod runner;
