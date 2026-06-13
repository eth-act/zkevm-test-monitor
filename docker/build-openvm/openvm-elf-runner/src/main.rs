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
    /// Verify an app proof.
    Verify { proof: PathBuf },
}

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
            match sdk.execute(bytes, StdIn::default()) {
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
        Cmd::Verify { proof } => {
            let app_vk: AppVerifyingKey = sdk.app_vk();
            let proof = read_object_from_file(&proof)?;
            verify_app_proof::<DefaultStarkEngine>(&app_vk, &proof)?;
        }
    }

    Ok(())
}
