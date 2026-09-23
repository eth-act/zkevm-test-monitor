//! Run one OpenVM guest ELF for the act-extra suite (execute only, no proving).
//!
//! Usage: openvm-extra-executor <elf> <input> <public-values-out>
//!
//! The VM config is the one eth-act/ere's OpenVM prover uses (`sdk_vm_config` in
//! ere-prover-openvm): OpenVM's standard config with 256 bytes of public values.
//! ere's accelerator layer is built for exactly this config. The input file is
//! written as ONE input vector, as ere's `execute` does (`StdIn::write_bytes`).
//! The program runs in the SDK's pure executor, and the public values (always
//! 256 bytes, zero-padded) are written to <public-values-out>.
//!
//! Exit status: 0 when the guest halted with exit code 0, 1 when execution
//! failed (including a non-zero guest exit code), 2 on a usage or I/O error.

use std::process::ExitCode;

use openvm_sdk::{
    config::{AggregationSystemParams, AppConfig},
    CpuSdk, StdIn,
};
use openvm_sdk_config::SdkVmConfig;
use openvm_stark_sdk::config::{app_params_with_100_bits_security, MAX_APP_LOG_STACKED_HEIGHT};

/// `NUM_PUBLIC_VALUES_BYTES` in ere-verifier-openvm.
const NUM_PUBLIC_VALUES_BYTES: usize = 256;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let [_, elf_path, input_path, output_path] = args.as_slice() else {
        eprintln!("usage: openvm-extra-executor <elf> <input> <public-values-out>");
        return ExitCode::from(2);
    };
    let (elf, input) = match (std::fs::read(elf_path), std::fs::read(input_path)) {
        (Ok(elf), Ok(input)) => (elf, input),
        (Err(e), _) | (_, Err(e)) => {
            eprintln!("error: read input files: {e}");
            return ExitCode::from(2);
        }
    };

    let mut vm_config = SdkVmConfig::standard();
    vm_config.system.config = vm_config
        .system
        .config
        .with_public_values_bytes(NUM_PUBLIC_VALUES_BYTES);
    let app_config = AppConfig::new(
        vm_config.optimize(),
        app_params_with_100_bits_security(MAX_APP_LOG_STACKED_HEIGHT),
    );
    let sdk = match CpuSdk::new(app_config, AggregationSystemParams::default()) {
        Ok(sdk) => sdk,
        Err(e) => {
            eprintln!("error: SDK setup: {e}");
            return ExitCode::from(2);
        }
    };

    let mut stdin = StdIn::default();
    stdin.write_bytes(&input);
    match sdk.compile_and_execute(elf, stdin) {
        Ok(public_values) => {
            if let Err(e) = std::fs::write(output_path, public_values) {
                eprintln!("error: write {output_path}: {e}");
                return ExitCode::from(2);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("execution failed: {e}");
            ExitCode::from(1)
        }
    }
}
