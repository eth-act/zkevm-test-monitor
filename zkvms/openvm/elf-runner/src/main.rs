//! Standalone OpenVM ACT4 runner: execute / prove / verify a RISC-V (RV64IM) ELF.
//!
//! ACT4 compliance ELFs are self-checking: they terminate via OpenVM's custom
//! terminate opcode with exit code 0 (pass) or non-zero (fail). The SDK surfaces a
//! non-zero guest exit as `Err`, so `execute` maps directly to the process exit code.
//!
//! Proving uses the cheapest level — an app-level continuation STARK proof
//! (`app_prover` / `verify_app_proof`), not the aggregated/EVM path. When built with
//! the `cuda` cargo feature, `Sdk`/`DefaultStarkEngine` resolve to the GPU engine, so
//! proving and verification run on the GPU with no source changes.

use std::path::PathBuf;
use std::process::exit;

use clap::{Parser, Subcommand};
use eyre::Result;
use openvm_sdk::{
    config::AggregationSystemParams,
    fs::{read_object_from_file, write_object_to_file},
    keygen::AppVerifyingKey,
    prover::verify_app_proof,
    DefaultStarkEngine, Sdk, StdIn,
};
use openvm_stark_sdk::config::{app_params_with_100_bits_security, MAX_APP_LOG_STACKED_HEIGHT};

#[derive(Parser)]
#[command(name = "openvm-binary", about = "OpenVM ACT4 execute/prove/verify runner (RV64IM)")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Execute an ELF. Exit 0 on clean guest halt(0); exit 1 on any guest failure.
    Execute { elf: PathBuf },
    /// Prove an ELF (app-level STARK) and write the proof to `--output`.
    Prove {
        elf: PathBuf,
        #[arg(short, long)]
        output: PathBuf,
    },
    /// Verify an app proof. The ELF argument is accepted for a uniform runner
    /// interface but is unused — the app verifying key derives from the VM config.
    Verify {
        proof: PathBuf,
        elf: Option<PathBuf>,
    },
}

/// Build the RV64IM SDK. The `cuda` cargo feature transparently switches this to the
/// GPU engine; the construction is identical for CPU and GPU.
fn make_sdk() -> Sdk {
    let app_params = app_params_with_100_bits_security(MAX_APP_LOG_STACKED_HEIGHT);
    let agg_params = AggregationSystemParams::default();
    Sdk::riscv64(app_params, agg_params)
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let sdk = make_sdk();

    match cli.cmd {
        Cmd::Execute { elf } => {
            let bytes = std::fs::read(&elf)?;
            match sdk.compile_and_execute(bytes, StdIn::default()) {
                Ok(_) => exit(0),
                Err(e) => {
                    eprintln!("execute failed for {}: {e}", elf.display());
                    exit(1);
                }
            }
        }
        Cmd::Prove { elf, output } => {
            let bytes = std::fs::read(&elf)?;
            let mut prover = sdk.app_prover(bytes)?.with_program_name("act4");
            let proof = prover.prove(StdIn::default())?;
            write_object_to_file(&output, proof)?;
        }
        Cmd::Verify { proof, elf: _ } => {
            let app_vk: AppVerifyingKey = sdk.app_vk();
            let proof = read_object_from_file(&proof)?;
            let _ = verify_app_proof::<DefaultStarkEngine>(&app_vk, &proof)?;
        }
    }

    Ok(())
}
