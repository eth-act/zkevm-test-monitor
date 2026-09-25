//! Host-side test runners for RISC-V zkVMs.
//!
//! Two binaries share this library:
//! - `act4-runner` runs the ACT4 ISA tests (pass = exit code 0, optionally prove and verify).
//! - `eth-act-standards-runner` runs the eth-act standards tests, which check the guest's
//!   public output against the I/O test vectors.

pub mod backends;
pub mod eth_act_standards;
pub mod results;
pub mod runner;
