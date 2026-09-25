//! Runs the eth-act standards test guests on one zkVM (execute only).
//!
//! Every guest ELF under `--elf-dir` runs with its I/O test vectors: the
//! private input `<stem>.input` (default: empty) and the expected public output
//! `<stem>.expected` (default: the verdict `PASS`). The group of a test is the
//! name of its parent directory (`io`, `accelerators`, `memory`).
//!
//! Writes `summary-eth-act-standards.json` and `results-eth-act-standards.json`
//! to `--output-dir`, and exits 1 if any test failed.

use std::path::{Path, PathBuf};
use std::process;

use act4_runner::eth_act_standards::{self, GuestRun};
use act4_runner::results::{self, TestEntry};
use act4_runner::runner;
use clap::Parser;

/// Suite id recorded in the result files and the history.
const SUITE: &str = "eth-act-standards";

#[derive(Parser)]
#[command(name = "eth-act-standards-runner")]
struct Cli {
    /// zkVM to run: zisk, sp1 or openvm.
    #[arg(long)]
    zkvm: String,

    /// Executor for that zkVM: ziskemu, sp1-eth-act-standards-executor or
    /// openvm-eth-act-standards-executor.
    #[arg(long)]
    executor: PathBuf,

    /// Directory containing the guest ELFs (searched recursively).
    #[arg(long)]
    elf_dir: PathBuf,

    /// Directory for the JSON result files.
    #[arg(long)]
    output_dir: PathBuf,

    /// Number of parallel jobs (default: auto-detect per zkVM).
    #[arg(short = 'j', long = "jobs")]
    jobs: Option<usize>,
}

fn main() {
    let cli = Cli::parse();

    let run_guest: fn(&Path, &Path) -> GuestRun = match cli.zkvm.as_str() {
        "zisk" => eth_act_standards::run_zisk,
        "sp1" => eth_act_standards::run_sp1,
        "openvm" => eth_act_standards::run_openvm,
        other => {
            eprintln!("error: unknown zkvm '{other}', expected one of: zisk, sp1, openvm");
            process::exit(2);
        }
    };
    let jobs = cli.jobs.unwrap_or_else(|| runner::default_jobs(&cli.zkvm));

    let entries: Vec<TestEntry> = runner::run_tests_with(
        &cli.elf_dir,
        jobs,
        |elf_path| run_guest(&cli.executor, elf_path),
        |guest_run| &guest_run.run,
    )
    .into_iter()
    .map(|(path, guest_run)| TestEntry::from_run(&path, &guest_run.run, guest_run.detail))
    .collect();

    if let Err(e) = std::fs::create_dir_all(&cli.output_dir) {
        eprintln!("error: failed to create output dir: {e}");
        process::exit(2);
    }
    if let Err(e) = results::write_results(&cli.output_dir, SUITE, &cli.zkvm, SUITE, &entries, true) {
        eprintln!("error: failed to write results: {e}");
        process::exit(2);
    }

    let passed = entries.iter().filter(|e| e.passed).count();
    let total = entries.len();
    if passed == total {
        println!("{passed}/{total} passed");
    } else {
        println!("{passed}/{total} passed ({} failed)", total - passed);
        process::exit(1);
    }
}
