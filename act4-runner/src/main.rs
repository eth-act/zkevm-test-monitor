mod backends;
mod elf_utils;
mod results;
mod runner;

use std::path::PathBuf;
use std::process;

use clap::Parser;

use crate::backends::{Backend, Mode};
use crate::results::TestEntry;

/// ACT4 compliance test runner for RISC-V ZK-VMs.
#[derive(Parser)]
#[command(name = "act4-runner")]
struct Cli {
    /// ZK-VM backend to use (airbender, airbender-prove, openvm, zisk, zisk-ere).
    #[arg(long)]
    zkvm: String,

    /// Path to the ZK-VM binary executable (not needed for zisk-ere).
    #[arg(long)]
    binary: Option<PathBuf>,

    /// Directory containing ELF test files (searched recursively).
    #[arg(long)]
    elf_dir: PathBuf,

    /// Directory for JSON output files.
    #[arg(long)]
    output_dir: PathBuf,

    /// Test suite name (e.g. "act4" or "act4-target").
    #[arg(long)]
    suite: String,

    /// Output file label (e.g. "full-isa" or "standard-isa").
    #[arg(long)]
    label: String,

    /// Number of parallel test jobs (default: auto-detect).
    #[arg(short = 'j', long = "jobs")]
    jobs: Option<usize>,

    /// Execution mode: execute (emulation only), prove (emulate + prove),
    /// full (emulate + prove + verify). Used by jolt-prove and zisk-prove.
    #[arg(long, default_value = "execute")]
    mode: String,

    /// Path to cargo-zisk binary (for zisk-prove backend).
    #[arg(long)]
    cargo_zisk: Option<PathBuf>,

    /// Path to jolt-prover binary (for jolt-prove backend).
    #[arg(long)]
    jolt_prover: Option<PathBuf>,

    /// Path to libzisk_witness.so (required for zisk-prove on v0.15.0).
    #[arg(long)]
    witness_lib: Option<PathBuf>,

    /// Enable GPU acceleration (airbender-prove, zisk-prove).
    #[arg(long)]
    gpu: bool,

    /// Directory for proof output artifacts (airbender-prove only).
    #[arg(long)]
    proof_output_dir: Option<PathBuf>,
}

fn main() {
    let cli = Cli::parse();

    let mode = match cli.mode.as_str() {
        "execute" => Mode::Execute,
        "prove" => Mode::Prove,
        "full" => Mode::Full,
        other => {
            eprintln!("error: unknown mode '{other}', expected one of: execute, prove, full");
            process::exit(2);
        }
    };

    let require_binary = |cli: &Cli| -> PathBuf {
        cli.binary.clone().unwrap_or_else(|| {
            eprintln!("error: --binary is required for zkvm '{}'", cli.zkvm);
            process::exit(2);
        })
    };

    let backend = match cli.zkvm.as_str() {
        "airbender" => Backend::Airbender {
            binary: require_binary(&cli),
        },
        "airbender-prove" => Backend::AirbenderProve {
            binary: require_binary(&cli),
            gpu: cli.gpu,
            proof_dir: cli
                .proof_output_dir
                .clone()
                .unwrap_or_else(|| cli.output_dir.join("proofs")),
        },
        "jolt" => Backend::Jolt {
            jolt_prover: cli.jolt_prover.clone().unwrap_or_else(|| {
                eprintln!("error: --jolt-prover is required for zkvm 'jolt'");
                process::exit(2);
            }),
        },
        "openvm" => Backend::OpenVM {
            binary: require_binary(&cli),
        },
        "zisk" => Backend::Zisk {
            binary: require_binary(&cli),
        },
        "zisk-prove" => Backend::ZiskProve {
            ziskemu: require_binary(&cli),
            cargo_zisk: cli.cargo_zisk.clone().unwrap_or_else(|| {
                eprintln!("error: --cargo-zisk is required for zkvm 'zisk-prove'");
                process::exit(2);
            }),
            witness_lib: cli.witness_lib.clone(),
            gpu: cli.gpu,
        },
        other => {
            eprintln!("error: unknown zkvm '{other}', expected one of: airbender, airbender-prove, jolt, openvm, zisk, zisk-prove");
            process::exit(2);
        }
    };

    // For prove/full modes, default to 1 job (proving is resource-intensive)
    let jobs = cli.jobs.unwrap_or_else(|| {
        if mode != Mode::Execute {
            1
        } else {
            runner::default_jobs(&cli.zkvm)
        }
    });

    let run_results = runner::run_tests(&backend, &cli.elf_dir, jobs, mode);

    let entries: Vec<TestEntry> = run_results
        .iter()
        .map(|(path, result)| {
            let extension = path
                .parent()
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str())
                .unwrap_or("unknown")
                .to_owned();
            let name = path
                .file_stem()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown")
                .to_owned();
            TestEntry {
                name,
                extension,
                passed: result.passed,
                prove_duration_secs: result.prove_duration.map(|d| d.as_secs_f64()),
                proof_written: if result.proof_written { Some(true) } else { None },
                prove_status: result.prove_status.clone(),
                verify_status: result.verify_status.clone(),
            }
        })
        .collect();

    if let Err(e) = std::fs::create_dir_all(&cli.output_dir) {
        eprintln!("error: failed to create output dir: {e}");
        process::exit(2);
    }

    if let Err(e) =
        results::write_results(&cli.output_dir, &cli.label, &cli.zkvm, &cli.suite, &entries)
    {
        eprintln!("error: failed to write results: {e}");
        process::exit(2);
    }

    let passed = entries.iter().filter(|e| e.passed).count();
    let total = entries.len();
    let failed = total - passed;

    // Print summary
    if failed == 0 {
        println!("{passed}/{total} passed");
    } else {
        println!("{passed}/{total} passed ({failed} failed)");
    }

    // Print prove/verify summary if applicable
    let proved: usize = entries.iter().filter(|e| e.prove_status.as_deref() == Some("success")).count();
    let prove_failed: usize = entries.iter().filter(|e| e.prove_status.as_deref() == Some("failed")).count();
    if proved + prove_failed > 0 {
        println!("proved: {proved}/{} ({}  failed)", proved + prove_failed, prove_failed);
    }
    let verified: usize = entries.iter().filter(|e| e.verify_status.as_deref() == Some("success")).count();
    let verify_failed: usize = entries.iter().filter(|e| e.verify_status.as_deref() == Some("failed")).count();
    if verified + verify_failed > 0 {
        println!("verified: {verified}/{} ({} failed)", verified + verify_failed, verify_failed);
    }

    if failed > 0 {
        process::exit(1);
    }
}
