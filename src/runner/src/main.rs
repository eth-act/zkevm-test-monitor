use std::path::PathBuf;
use std::process;

use clap::Parser;
use runner::backends::{self, Backend, Mode, Prover, ProverTools, Zkvm};
use runner::results::{self, TestEntry};
use runner::runner as suite;

/// Test runner for RISC-V ZK-VMs: the ACT4 ISA tests and the eth-act
/// standards tests.
///
/// Every ELF may have `<stem>.input`, `<stem>.expected` and `<stem>.outcome`
/// files next to it (see the `io` module).
#[derive(Parser)]
#[command(name = "runner")]
struct Cli {
    /// ZK-VM backend to use. ISA tests: lambdavm, openvm, openvm-prove,
    /// sp1-prove, zisk, zisk-prove. eth-act standards tests: zisk-standards,
    /// sp1-standards, openvm-standards.
    #[arg(long)]
    zkvm: String,

    /// Path to the ZK-VM binary executable (for the standards backends:
    /// ziskemu, sp1-eth-act-standards-executor or
    /// openvm-eth-act-standards-executor).
    #[arg(long)]
    binary: Option<PathBuf>,

    /// Directory containing ELF test files (searched recursively).
    #[arg(long)]
    elf_dir: PathBuf,

    /// Directory for JSON output files.
    #[arg(long)]
    output_dir: PathBuf,

    /// Test suite name (e.g. "act4-full" or "eth-act-standards").
    #[arg(long)]
    suite: String,

    /// ISA output file label (e.g. "full-isa" or "standard-isa"): the files are
    /// `summary-act4-<label>.json` and `results-act4-<label>.json`. Without
    /// it, the files are `summary-<suite>.json` and `results-<suite>.json`.
    #[arg(long)]
    label: Option<String>,

    /// Also record each test's group (its parent directory) and failure
    /// detail in the results file.
    #[arg(long)]
    groups: bool,

    /// Number of parallel test jobs (default: auto-detect).
    #[arg(short = 'j', long = "jobs")]
    jobs: Option<usize>,

    /// Execution mode: execute (emulation only), prove (emulate + prove),
    /// full (emulate + prove + verify). Used by the prove backends.
    #[arg(long, default_value = "execute")]
    mode: String,

    /// Path to cargo-zisk binary (for zisk-prove backend).
    #[arg(long)]
    cargo_zisk: Option<PathBuf>,

    /// Path to sp1-perf binary (prove+verify; for sp1-prove backend).
    #[arg(long)]
    sp1_perf: Option<PathBuf>,

    /// Path to libzisk_witness.so (required for zisk-prove on v0.15.0).
    #[arg(long)]
    witness_lib: Option<PathBuf>,

    /// Enable GPU acceleration (openvm-prove, sp1-prove, zisk-prove).
    #[arg(long)]
    gpu: bool,

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

    let Some((zkvm, suite_kind, prove)) = backends::parse_name(&cli.zkvm) else {
        eprintln!(
            "error: unknown zkvm '{}', expected one of: lambdavm, openvm, openvm-prove, sp1-prove, \
             zisk, zisk-prove, zisk-standards, sp1-standards, openvm-standards",
            cli.zkvm
        );
        process::exit(2);
    };
    let binary = require_binary(&cli);
    let prove = prove.then(|| {
        let tools = match zkvm {
            Zkvm::Sp1 => ProverTools::Sp1 {
                sp1_perf: cli.sp1_perf.clone().unwrap_or_else(|| {
                    eprintln!("error: --sp1-perf is required for zkvm 'sp1-prove'");
                    process::exit(2);
                }),
            },
            Zkvm::OpenVM => ProverTools::OpenVM,
            Zkvm::Zisk => ProverTools::Zisk {
                cargo_zisk: cli.cargo_zisk.clone().unwrap_or_else(|| {
                    eprintln!("error: --cargo-zisk is required for zkvm 'zisk-prove'");
                    process::exit(2);
                }),
                witness_lib: cli.witness_lib.clone(),
            },
            Zkvm::LambdaVM => {
                eprintln!("error: zkvm 'lambdavm' has no prover");
                process::exit(2);
            }
        };
        Prover { gpu: cli.gpu, tools }
    });
    let backend = Backend::new(zkvm, suite_kind, binary, prove).unwrap_or_else(|e| {
        eprintln!("error: {e}");
        process::exit(2);
    });

    // For prove/full modes, default to 1 job (proving is resource-intensive)
    let jobs = cli.jobs.unwrap_or_else(|| {
        if mode != Mode::Execute {
            1
        } else {
            suite::default_jobs(&cli.zkvm)
        }
    });

    let entries: Vec<TestEntry> = suite::run_tests(&backend, &cli.elf_dir, jobs, mode)
        .iter()
        .map(|(path, result)| TestEntry::from_run(path, result))
        .collect();

    if let Err(e) = std::fs::create_dir_all(&cli.output_dir) {
        eprintln!("error: failed to create output dir: {e}");
        process::exit(2);
    }

    let file_stem = match &cli.label {
        Some(label) => format!("act4-{label}"),
        None => cli.suite.clone(),
    };
    if let Err(e) = results::write_results(
        &cli.output_dir,
        &file_stem,
        &cli.zkvm,
        &cli.suite,
        &entries,
        cli.groups,
    ) {
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
