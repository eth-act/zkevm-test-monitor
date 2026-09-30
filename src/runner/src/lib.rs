//! Host-side test runner for RISC-V zkVMs.
//!
//! One binary, `runner`, runs both suites:
//! - the ACT4 ISA tests (pass = clean exit, optionally prove and verify);
//! - the eth-act standards tests, which check the guest's public output
//!   against its I/O test vectors.
//!
//! Every backend reads the optional per-ELF files `<stem>.input`,
//! `<stem>.expected` and `<stem>.outcome` (see `io_and_expected_failures`).

pub mod zkvm_backends;
// The ere backend is behind the `ere` cargo feature, so the native path's build does
// not fetch or compile ere-dockerized (a git dependency with its own Docker and HTTP
// client crates). src/run-isa-tests.sh builds the ere runner with `--features ere`
// into target/ere. See the `[features]` note in Cargo.toml.
#[cfg(feature = "ere")]
pub mod ere_backend;
pub mod io_and_expected_failures;
pub mod results;
pub mod runner;
