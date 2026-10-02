//! Run, prove or verify one OpenVM guest ELF for the eth-act standards tests.
//!
//! Usage:
//!   openvm-eth-act-standards-executor <elf> <input> <public-values-out> <exit-code-out>
//!   openvm-eth-act-standards-executor prove <elf> <input> <proof-out>
//!   openvm-eth-act-standards-executor verify <proof>
//!
//! The VM config is the one eth-act/ere's OpenVM prover uses (`sdk_vm_config` in
//! ere-prover-openvm): OpenVM's standard config with 256 bytes of public values.
//! ere's accelerator layer is built for exactly this config. The input file is
//! written as ONE input vector, as ere's `execute` does (`StdIn::write_bytes`).
//! The program runs in the SDK's pure executor, and the public values (always
//! 256 bytes, zero-padded) are written to <public-values-out>.
//!
//! Exit status: 0 when the guest halted with exit code 0, 1 when the guest
//! terminated abnormally (a non-zero exit code, or an execution that OpenVM
//! rejected), 2 on a usage, I/O, SDK or compile error. When the guest's exit
//! code is known, it is written (decimal) to <exit-code-out>.
//!
//! `prove` writes an app-level continuation STARK proof of the same execution
//! (same VM config, same input vector), and `verify` checks one against the
//! app verifying key. Both exit 0 on success, 1 when proving or verification
//! fails, and 2 on a usage or I/O error. With the `cuda` feature, both run on
//! the GPU.

use std::process::ExitCode;

use openvm_sdk::{
    config::{AggregationSystemParams, AppConfig},
    fs::{read_object_from_file, write_object_to_file},
    openvm_circuit::arch::{ExecutionError, VirtualMachineError},
    prover::verify_app_proof,
    DefaultStarkEngine, Sdk, SdkError, StdIn,
};
use openvm_sdk_config::SdkVmConfig;
use openvm_stark_sdk::config::{app_params_with_100_bits_security, MAX_APP_LOG_STACKED_HEIGHT};

/// `NUM_PUBLIC_VALUES_BYTES` in ere-verifier-openvm.
const NUM_PUBLIC_VALUES_BYTES: usize = 256;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match args.as_slice() {
        [_, cmd, elf_path, input_path, proof_path] if cmd == "prove" => {
            prove(elf_path, input_path, proof_path)
        }
        [_, cmd, proof_path] if cmd == "verify" => verify(proof_path),
        [_, elf_path, input_path, output_path, code_path] => {
            run(elf_path, input_path, output_path, code_path)
        }
        _ => {
            eprintln!(
                "usage: openvm-eth-act-standards-executor <elf> <input> <public-values-out> <exit-code-out>\n\
                 \x20      openvm-eth-act-standards-executor prove <elf> <input> <proof-out>\n\
                 \x20      openvm-eth-act-standards-executor verify <proof>"
            );
            ExitCode::from(2)
        }
    }
}

/// The SDK for ere's OpenVM VM config. With the `cuda` feature, `Sdk` is the GPU SDK.
fn make_sdk() -> Result<Sdk, SdkError> {
    let mut vm_config = SdkVmConfig::standard();
    vm_config.system.config = vm_config
        .system
        .config
        .with_public_values_bytes(NUM_PUBLIC_VALUES_BYTES);
    let app_config = AppConfig::new(
        vm_config.optimize(),
        app_params_with_100_bits_security(MAX_APP_LOG_STACKED_HEIGHT),
    );
    Sdk::new(app_config, AggregationSystemParams::default())
}

/// The input file as ONE input vector, as ere writes it.
fn std_in(input: &[u8]) -> StdIn {
    let mut stdin = StdIn::default();
    stdin.write_bytes(input);
    stdin
}

fn prove(elf_path: &str, input_path: &str, proof_path: &str) -> ExitCode {
    let (elf, input) = match (std::fs::read(elf_path), std::fs::read(input_path)) {
        (Ok(elf), Ok(input)) => (elf, input),
        (Err(e), _) | (_, Err(e)) => {
            eprintln!("error: read input files: {e}");
            return ExitCode::from(2);
        }
    };
    let proof = make_sdk()
        .and_then(|sdk| sdk.app_prover(elf))
        .map_err(|e| e.to_string())
        .and_then(|mut prover| prover.prove(std_in(&input)).map_err(|e| e.to_string()));
    match proof {
        Ok(proof) => match write_object_to_file(proof_path, proof) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("error: write {proof_path}: {e}");
                ExitCode::from(2)
            }
        },
        Err(e) => {
            eprintln!("prove failed: {e}");
            ExitCode::from(1)
        }
    }
}

fn verify(proof_path: &str) -> ExitCode {
    let proof = match read_object_from_file(proof_path) {
        Ok(proof) => proof,
        Err(e) => {
            eprintln!("error: read {proof_path}: {e}");
            return ExitCode::from(2);
        }
    };
    let verified = make_sdk().map_err(|e| e.to_string()).and_then(|sdk| {
        verify_app_proof::<DefaultStarkEngine>(&sdk.app_vk(), &proof).map_err(|e| e.to_string())
    });
    match verified {
        Ok(_) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("verify failed: {e}");
            ExitCode::from(1)
        }
    }
}

fn run(elf_path: &str, input_path: &str, output_path: &str, code_path: &str) -> ExitCode {
    let (elf, input) = match (std::fs::read(elf_path), std::fs::read(input_path)) {
        (Ok(elf), Ok(input)) => (elf, input),
        (Err(e), _) | (_, Err(e)) => {
            eprintln!("error: read input files: {e}");
            return ExitCode::from(2);
        }
    };

    let sdk = match make_sdk() {
        Ok(sdk) => sdk,
        Err(e) => {
            eprintln!("error: SDK setup: {e}");
            return ExitCode::from(2);
        }
    };

    let compiled = match sdk.compile(elf) {
        Ok(compiled) => compiled,
        Err(e) => {
            eprintln!("error: compile: {e}");
            return ExitCode::from(2);
        }
    };

    let (status, code) = match sdk.execute(&compiled, std_in(&input)) {
        Ok(public_values) => {
            if let Err(e) = std::fs::write(output_path, public_values) {
                eprintln!("error: write {output_path}: {e}");
                return ExitCode::from(2);
            }
            (ExitCode::SUCCESS, Some(0))
        }
        Err(SdkError::Vm(VirtualMachineError::Execution(e))) if is_guest_error(&e) => {
            eprintln!("execution failed: {e}");
            let code = match e {
                ExecutionError::FailedWithExitCode(code) => Some(code),
                _ => None,
            };
            (ExitCode::from(1), code)
        }
        Err(e) => {
            eprintln!("error: execution: {e}");
            return ExitCode::from(2);
        }
    };
    if let Some(code) = code {
        if let Err(e) = std::fs::write(code_path, code.to_string()) {
            eprintln!("error: write {code_path}: {e}");
            return ExitCode::from(2);
        }
    }
    status
}

/// Whether the guest caused the error (OpenVM rejected its execution), as
/// opposed to the VM's configuration or the executor.
fn is_guest_error(e: &ExecutionError) -> bool {
    matches!(
        e,
        ExecutionError::FailedWithExitCode(_)
            | ExecutionError::Fail { .. }
            | ExecutionError::PcOutOfBounds(_)
            | ExecutionError::Unreachable(_)
            | ExecutionError::DisabledOperation { .. }
            | ExecutionError::HintOutOfBounds { .. }
            | ExecutionError::HintBufferZeroWords { .. }
            | ExecutionError::HintBufferTooLarge { .. }
            | ExecutionError::PublicValueIndexOutOfBounds { .. }
            | ExecutionError::PublicValueNotEqual { .. }
            | ExecutionError::PhantomNotFound { .. }
            | ExecutionError::Phantom { .. }
            | ExecutionError::DidNotTerminate
    )
}
