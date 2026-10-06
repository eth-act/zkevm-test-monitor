use std::path::PathBuf;
use std::process;

use clap::Parser;
use runner::zkvm_backends::{self, Mode, RunResult, Termination, Tools};
use runner::results::{self, TestEntry};
use runner::runner::{self as suite, Suite};

/// Test runner for RISC-V ZK-VMs: the ACT4 ISA tests and the eth-act
/// standards tests.
///
/// Every ELF may have `<stem>.input`, `<stem>.expected` and `<stem>.outcome`
/// files next to it (see the `io_and_expected_failures` module).
///
/// Exit status: 0 when every test passed, 1 when a test failed, 2 on a usage
/// error or when the ELF directory holds no ELFs, 3 when a test could not run
/// (a host error), so the results are not a valid run.
#[derive(Parser)]
#[command(name = "runner")]
struct Cli {
    /// ZK-VM backend to use: lambdavm, openvm, sp1 or zisk. With `--features ere`:
    /// ere-openvm, ere-sp1 or ere-zisk (the ere path).
    #[arg(long)]
    zkvm: String,

    /// Path to the ZK-VM's own executor: lambdavm, openvm-binary,
    /// sp1-perf-executor or ziskemu.
    #[arg(long)]
    binary: Option<PathBuf>,

    /// Path to an eth-act standards executor, which runs a guest with I/O,
    /// instead of --binary (openvm: openvm-eth-act-standards-executor; sp1:
    /// sp1-eth-act-standards-executor).
    #[arg(long)]
    io_executor: Option<PathBuf>,

    /// Directory containing ELF test files (searched recursively).
    #[arg(long)]
    elf_dir: PathBuf,

    /// Run only the selected tests: words separated by spaces or commas, each
    /// a test name or a group (an ELF's parent directory), else a pattern on
    /// the test names (a glob with `*` and `?`, or a substring).
    #[arg(long)]
    select: Vec<String>,

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
    /// full (emulate + prove + verify). Proving needs the zkVM's prover tools.
    #[arg(long, default_value = "execute")]
    mode: String,

    /// Path to cargo-zisk binary (to prove with zisk).
    #[arg(long)]
    cargo_zisk: Option<PathBuf>,

    /// Path to sp1-perf binary (prove+verify; to prove with sp1).
    #[arg(long)]
    sp1_perf: Option<PathBuf>,

    /// Path to libzisk_witness.so (required to prove with zisk v0.15.0).
    #[arg(long)]
    witness_lib: Option<PathBuf>,

    /// Enable GPU acceleration (openvm and sp1 proving; zisk uses the GPU
    /// when cargo-zisk is a cuda build).
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

    let Some(suite_kind) = Suite::from_name(&cli.suite) else {
        eprintln!("error: unknown suite '{}', expected act4-<name> or eth-act-standards", cli.suite);
        process::exit(2);
    };

    let elfs = suite::find_elfs(&cli.elf_dir, &cli.select).unwrap_or_else(|e| {
        eprintln!("error: {e}");
        process::exit(2);
    });
    if !cli.select.is_empty() {
        eprintln!("Selected {} tests", elfs.len());
    }

    // The ere path (`--zkvm ere-<zkvm>`, `--features ere`) runs the ELFs on the official
    // ere images. ere runs its own execute, prove and verify stages, so it is not a
    // `Zkvm` backend. It runs one test at a time: one server per zkVM.
    #[cfg(feature = "ere")]
    if let Some(name) = cli.zkvm.strip_prefix("ere-") {
        let standards = suite_kind == Suite::Standards;
        let (ere, provenance) = runner::ere_backend::EreBackend::new(name, cli.gpu, standards).unwrap_or_else(|e| {
            eprintln!("error: {e:#}");
            process::exit(2);
        });
        let runs = suite::run_elfs(&elfs, 1, |elf| {
            suite::run_one_with(&cli.zkvm, suite_kind, elf, |elf, vectors| {
                ere.run_elf(elf, mode, vectors, std::time::Instant::now())
            })
        });
        let label = cli.label.as_deref().unwrap_or(&cli.suite);
        report(&cli, &runs, || ere.finish(&cli.output_dir, label, &provenance));
        return;
    }

    let tools = Tools {
        binary: cli.binary.clone(),
        io_executor: cli.io_executor.clone(),
        sp1_perf: cli.sp1_perf.clone(),
        cargo_zisk: cli.cargo_zisk.clone(),
        witness_lib: cli.witness_lib.clone(),
        gpu: cli.gpu,
    };
    let zkvm = zkvm_backends::build(&cli.zkvm, tools)
        .and_then(|zkvm| suite::check_mode(&*zkvm, mode).map(|()| zkvm))
        .unwrap_or_else(|e| {
            eprintln!("error: {e}");
            process::exit(2);
        });

    // For prove/full modes, default to 1 job (proving is resource-intensive).
    let jobs = cli.jobs.unwrap_or_else(|| {
        if mode != Mode::Execute {
            1
        } else {
            suite::default_jobs(&cli.zkvm)
        }
    });

    let runs = suite::run_tests(&*zkvm, suite_kind, &elfs, jobs, mode);
    report(&cli, &runs, || Ok(()));
}

/// Write the results and summary, run `finish` (the ere run records), print
/// the summary and exit with the runner's status.
fn report(cli: &Cli, runs: &[(PathBuf, RunResult)], finish: impl FnOnce() -> anyhow::Result<()>) {
    if runs.is_empty() {
        eprintln!("error: no ELFs found in {}", cli.elf_dir.display());
        process::exit(2);
    }
    let host_errors = runs.iter().filter(|(_, result)| result.termination == Termination::HostError).count();
    let entries: Vec<TestEntry> = runs.iter().map(|(path, result)| TestEntry::from_run(path, result)).collect();

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

    if let Err(e) = finish() {
        eprintln!("error: failed to write ere run records: {e:#}");
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

    if host_errors > 0 {
        eprintln!("error: {host_errors} test(s) could not run (host errors); the results are not a valid run");
        process::exit(3);
    }
    if failed > 0 {
        process::exit(1);
    }
}
