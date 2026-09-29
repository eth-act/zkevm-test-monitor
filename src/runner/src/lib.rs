//! Host-side test runner for RISC-V zkVMs.
//!
//! One binary, `runner`, runs both suites:
//! - the ACT4 ISA tests (pass = clean exit, optionally prove and verify);
//! - the eth-act standards tests, which check the guest's public output
//!   against its I/O test vectors.
//!
//! There is one backend per zkVM (`backends::Zkvm`). The runner reads the
//! optional per-ELF files `<stem>.input`, `<stem>.expected` and
//! `<stem>.outcome` (see `io_and_expected_failures`) and judges every
//! execution the same way for both suites (`runner::judge`).

pub mod backends;
pub mod io_and_expected_failures;
pub mod results;
pub mod runner;
