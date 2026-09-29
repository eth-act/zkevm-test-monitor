use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::Context;

use crate::io_and_expected_failures;

/// The `--zkvm` names.
pub const ZKVMS: [&str; 4] = ["lambdavm", "openvm", "sp1", "zisk"];

/// A zkVM backend: it runs a guest ELF and, with its prover tools, proves
/// and verifies it.
///
/// A backend reports what the zkVM did. The runner judges the result against
/// the test's expectations (`runner::judge`), the same way for both suites.
pub trait Zkvm: Sync {
    /// The zkVM's name for `--zkvm`.
    fn name(&self) -> &'static str;

    /// Whether `execute` can feed an input and report the public output.
    fn supports_io(&self) -> bool;

    /// Whether the backend has the tools to prove.
    fn can_prove(&self) -> bool;

    /// Run the ELF once. `input` is `None` unless `supports_io`.
    fn execute(&self, elf_path: &Path, input: Option<&[u8]>) -> Execution;

    /// Prove the ELF, and verify the proof with `verify`. The runner calls
    /// this only after an execution that passed. An error is a runner error.
    fn prove(&self, elf_path: &Path, input: Option<&[u8]>, verify: bool) -> anyhow::Result<Proof>;
}

/// The tool paths from the command line. Each zkVM uses the ones it needs.
#[derive(Default)]
pub struct Tools {
    /// The zkVM's own executor (`--binary`).
    pub binary: Option<PathBuf>,
    /// An eth-act standards executor (`--io-executor`).
    pub io_executor: Option<PathBuf>,
    pub sp1_perf: Option<PathBuf>,
    pub cargo_zisk: Option<PathBuf>,
    pub witness_lib: Option<PathBuf>,
    pub gpu: bool,
}

/// Build the backend for `--zkvm <name>`.
pub fn build(name: &str, tools: Tools) -> anyhow::Result<Box<dyn Zkvm>> {
    let Tools { binary, io_executor, sp1_perf, cargo_zisk, witness_lib, gpu } = tools;
    let executor = || -> anyhow::Result<Executor> {
        match (binary.clone(), io_executor.clone()) {
            (Some(binary), None) => Ok(Executor::Cli(binary)),
            (None, Some(executor)) => Ok(Executor::Io(executor)),
            (Some(_), Some(_)) => anyhow::bail!("give --binary or --io-executor for zkvm '{name}', not both"),
            (None, None) => anyhow::bail!("--binary or --io-executor is required for zkvm '{name}'"),
        }
    };
    let binary_only = || -> anyhow::Result<PathBuf> {
        if io_executor.is_some() {
            anyhow::bail!("zkvm '{name}' takes no --io-executor");
        }
        binary.clone().ok_or_else(|| anyhow::anyhow!("--binary is required for zkvm '{name}'"))
    };
    Ok(match name {
        "lambdavm" => Box::new(LambdaVM { binary: binary_only()? }),
        "openvm" => Box::new(OpenVM { executor: executor()?, gpu }),
        "sp1" => Box::new(Sp1 { executor: executor()?, sp1_perf, gpu }),
        "zisk" => Box::new(Zisk { ziskemu: binary_only()?, cargo_zisk, witness_lib }),
        other => anyhow::bail!("unknown zkvm '{other}', expected one of: {}", ZKVMS.join(", ")),
    })
}

/// The program that runs a guest ELF, for a zkVM that has two.
pub enum Executor {
    /// The zkVM's own executor (`--binary`). It takes no input.
    Cli(PathBuf),
    /// An eth-act standards executor (`--io-executor`):
    /// `<executor> <elf> <input file> <public output file> <exit code file>`.
    Io(PathBuf),
}

/// Execution mode for test runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Emulation only — check exit code.
    Execute,
    /// Emulation + proof generation.
    Prove,
    /// Emulation + proof generation + verification.
    Full,
}

/// How the guest execution ended, in the terms of the eth-act standard
/// termination semantics (zkevm-standards `standard-termination-semantics`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Termination {
    /// The guest terminated successfully (its output may still mismatch).
    Success,
    /// The guest terminated abnormally: a panic, an abort, a failed check, a
    /// non-zero return from `main`, or an execution that the zkVM rejected.
    /// `code` is the error code when the zkVM reports it.
    Failure { code: Option<i32> },
    /// The host could not run the guest to an outcome: a usage or I/O error,
    /// an executor killed by a signal, or a runner error. This is never a
    /// guest outcome, so it never passes a test.
    HostError,
}

impl Termination {
    /// `Success` for a successful execution, `Failure` without a code otherwise.
    pub fn from_success(success: bool) -> Self {
        if success { Termination::Success } else { Termination::Failure { code: None } }
    }
}

/// Whether the guest reached the ACT4 pass halt (`RVMODEL_HALT_PASS`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PassHalt {
    /// The zkVM cannot tell the pass halt from another successful
    /// termination, such as a return from `main`.
    Unknown,
    Reached,
    /// The guest terminated successfully without the pass halt; the string
    /// says why the zkVM knows.
    Missed(String),
}

/// A guest's public output.
pub struct PublicOutput {
    pub bytes: Vec<u8>,
    pub area: OutputArea,
}

/// What a backend reports about one run of a guest.
pub struct Execution {
    pub termination: Termination,
    /// The executor's exit code (`None`: killed by a signal, or not run).
    pub exit_code: Option<i32>,
    /// The public output of a successful termination, if the zkVM reports one.
    pub output: Option<PublicOutput>,
    pub pass_halt: PassHalt,
    /// Why the guest terminated abnormally, or why the host failed.
    pub detail: Option<String>,
}

impl Execution {
    /// An execution that only the executor's exit status reports.
    fn from_status(exit_code: Option<i32>, success: bool) -> Self {
        Execution {
            termination: Termination::from_success(success),
            exit_code,
            output: None,
            pass_halt: PassHalt::Unknown,
            detail: None,
        }
    }

    /// A successful termination with its public output.
    fn success(exit_code: Option<i32>, output: PublicOutput, pass_halt: PassHalt) -> Self {
        Execution { termination: Termination::Success, exit_code, output: Some(output), pass_halt, detail: None }
    }

    /// An abnormal termination.
    fn failure(exit_code: Option<i32>, code: Option<i32>, detail: String) -> Self {
        Execution {
            termination: Termination::Failure { code },
            exit_code,
            output: None,
            pass_halt: PassHalt::Unknown,
            detail: Some(detail),
        }
    }

    /// The host could not run the guest to an outcome.
    pub fn host_error(exit_code: Option<i32>, detail: String) -> Self {
        Execution {
            termination: Termination::HostError,
            exit_code,
            output: None,
            pass_halt: PassHalt::Unknown,
            detail: Some(detail),
        }
    }
}

/// The result of `Zkvm::prove`.
pub struct Proof {
    pub duration: Duration,
    pub written: bool,
    pub proved: bool,
    /// `None`: not verified.
    pub verified: Option<bool>,
}

impl Proof {
    /// Proving succeeded, and verification gave `verified`.
    fn proved(duration: Duration, written: bool, verified: Option<bool>) -> Self {
        Proof { duration, written, proved: true, verified }
    }

    /// Proving failed.
    fn failed(duration: Duration) -> Self {
        Proof { duration, written: false, proved: false, verified: None }
    }
}

/// Outcome of running a single test ELF through a backend.
#[allow(dead_code)]
pub struct RunResult {
    pub passed: bool,
    pub exit_code: Option<i32>,
    pub duration: Duration,
    pub prove_duration: Option<Duration>,
    pub proof_written: bool,
    /// "success", "failed", or None (not attempted).
    pub prove_status: Option<String>,
    /// "success", "failed", or None (not attempted).
    pub verify_status: Option<String>,
    pub termination: Termination,
    /// Why the test failed, when the backend reports it.
    pub detail: Option<String>,
}

impl RunResult {
    /// The result of an execution without proving.
    pub fn executed(
        start: Instant,
        exit_code: Option<i32>,
        termination: Termination,
        detail: Option<String>,
    ) -> Self {
        RunResult {
            passed: termination == Termination::Success && detail.is_none(),
            exit_code,
            duration: start.elapsed(),
            prove_duration: None,
            proof_written: false,
            prove_status: None,
            verify_status: None,
            termination,
            detail,
        }
    }

    /// The result when the host could not run the guest to an outcome.
    pub fn host_error(start: Instant, exit_code: Option<i32>, detail: String) -> Self {
        Self::executed(start, exit_code, Termination::HostError, Some(detail))
    }

    /// Add the result of proving.
    pub fn with_proof(self, proof: Proof) -> Self {
        let status = |ok: bool| if ok { "success" } else { "failed" }.to_owned();
        RunResult {
            prove_duration: Some(proof.duration),
            proof_written: proof.written,
            prove_status: Some(status(proof.proved)),
            verify_status: proof.verified.map(status),
            ..self
        }
    }
}

/// Fail `prove` for a prover that takes no input.
fn no_prover_input(name: &str, input: Option<&[u8]>) -> anyhow::Result<()> {
    if input.is_some() {
        anyhow::bail!("the {name} prover cannot take an input");
    }
    Ok(())
}

/// LambdaVM: the `lambdavm` CLI (`--binary`) executes, proves and verifies
/// (see `prove_lambdavm`).
pub struct LambdaVM {
    pub binary: PathBuf,
}

impl Zkvm for LambdaVM {
    fn name(&self) -> &'static str {
        "lambdavm"
    }

    fn supports_io(&self) -> bool {
        false
    }

    fn can_prove(&self) -> bool {
        true
    }

    fn execute(&self, elf_path: &Path, _input: Option<&[u8]>) -> Execution {
        let output = Command::new(&self.binary)
            .arg("execute")
            .arg(elf_path)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output();
        match output {
            Ok(o) => Execution::from_status(o.status.code(), o.status.success()),
            Err(e) => runner_error(elf_path, e.into()),
        }
    }

    fn prove(&self, elf_path: &Path, input: Option<&[u8]>, verify: bool) -> anyhow::Result<Proof> {
        no_prover_input(self.name(), input)?;
        prove_lambdavm(&self.binary, elf_path, verify)
    }
}

/// OpenVM: `openvm-binary` (`--binary`) executes, proves and verifies; the
/// eth-act standards executor (`--io-executor`) runs a guest with I/O.
pub struct OpenVM {
    pub executor: Executor,
    pub gpu: bool,
}

impl Zkvm for OpenVM {
    fn name(&self) -> &'static str {
        "openvm"
    }

    fn supports_io(&self) -> bool {
        matches!(self.executor, Executor::Io(_))
    }

    fn can_prove(&self) -> bool {
        matches!(self.executor, Executor::Cli(_))
    }

    fn execute(&self, elf_path: &Path, input: Option<&[u8]>) -> Execution {
        match &self.executor {
            Executor::Cli(binary) => run_openvm(binary, elf_path),
            Executor::Io(executor) => run_io_executor(executor, elf_path, input, OutputArea::ZeroPadded),
        }
    }

    fn prove(&self, elf_path: &Path, input: Option<&[u8]>, verify: bool) -> anyhow::Result<Proof> {
        no_prover_input(self.name(), input)?;
        let Executor::Cli(binary) = &self.executor else {
            anyhow::bail!("openvm proves with openvm-binary (--binary)");
        };
        prove_openvm(binary, elf_path, verify, self.gpu)
    }
}

/// SP1: `sp1-perf-executor` (`--binary`) or the eth-act standards executor
/// (`--io-executor`) runs a guest; `sp1-perf` (`--sp1-perf`) proves and
/// verifies.
pub struct Sp1 {
    pub executor: Executor,
    pub sp1_perf: Option<PathBuf>,
    pub gpu: bool,
}

impl Zkvm for Sp1 {
    fn name(&self) -> &'static str {
        "sp1"
    }

    fn supports_io(&self) -> bool {
        matches!(self.executor, Executor::Io(_))
    }

    fn can_prove(&self) -> bool {
        self.sp1_perf.is_some()
    }

    fn execute(&self, elf_path: &Path, input: Option<&[u8]>) -> Execution {
        match &self.executor {
            Executor::Cli(executor) => run_sp1(executor, elf_path),
            Executor::Io(executor) => run_io_executor(executor, elf_path, input, OutputArea::Exact),
        }
    }

    fn prove(&self, elf_path: &Path, input: Option<&[u8]>, verify: bool) -> anyhow::Result<Proof> {
        no_prover_input(self.name(), input)?;
        let Some(sp1_perf) = &self.sp1_perf else {
            anyhow::bail!("sp1 needs --sp1-perf to prove");
        };
        prove_sp1(sp1_perf, elf_path, verify, self.gpu)
    }
}

/// ZisK: `ziskemu` (`--binary`) runs a guest with I/O; `cargo-zisk`
/// (`--cargo-zisk`) proves and verifies.
pub struct Zisk {
    pub ziskemu: PathBuf,
    pub cargo_zisk: Option<PathBuf>,
    /// `libzisk_witness.so`, for a `cargo-zisk` that accepts `--witness-lib`.
    pub witness_lib: Option<PathBuf>,
}

impl Zkvm for Zisk {
    fn name(&self) -> &'static str {
        "zisk"
    }

    fn supports_io(&self) -> bool {
        true
    }

    fn can_prove(&self) -> bool {
        self.cargo_zisk.is_some()
    }

    fn execute(&self, elf_path: &Path, input: Option<&[u8]>) -> Execution {
        run_zisk(&self.ziskemu, elf_path, input)
    }

    fn prove(&self, elf_path: &Path, input: Option<&[u8]>, verify: bool) -> anyhow::Result<Proof> {
        no_prover_input(self.name(), input)?;
        let Some(cargo_zisk) = &self.cargo_zisk else {
            anyhow::bail!("zisk needs --cargo-zisk to prove");
        };
        prove_zisk(cargo_zisk, self.witness_lib.as_deref(), elf_path, verify)
    }
}

/// A runner error: log it and report a host error.
fn runner_error(elf_path: &Path, e: anyhow::Error) -> Execution {
    eprintln!("error running {}: {e}", elf_path.display());
    Execution::host_error(None, format!("runner error: {e:#}"))
}

/// Zisk proving via `cargo-zisk prove [--verify-proofs]`, after an execution
/// that passed (`run_zisk`):
/// `cargo-zisk prove --elf <path> -o <file> [--verify-proof] [--gpu]`
///
/// As of zisk v0.17.0, `-o/--output` is a file path (not a directory) and proofs
/// are aggregated by default (VadcopFinal). In v1.0.0 the Rust emulator became the
/// default (old `--emulator` flag removed), `prove` runs the per-program setup
/// internally, and `--verify-proofs` was renamed `--verify-proof` (in-process verify).
/// If the command fails, we parse stdout to distinguish prove vs verify failure:
/// the presence of "VERIFYING_PROOFS" or "was not verified" means proving
/// succeeded but verification failed.
fn prove_zisk(
    cargo_zisk: &Path,
    witness_lib: Option<&Path>,
    elf_path: &Path,
    verify: bool,
) -> anyhow::Result<Proof> {
    // Check once whether this cargo-zisk accepts --witness-lib
    let accepts_witness_lib = witness_lib.is_some()
        && Command::new(cargo_zisk)
            .args(["prove", "--help"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains("--witness-lib"))
            .unwrap_or(false);

    let is_gpu = cargo_zisk.to_string_lossy().contains("cuda");

    // Prove (with --verify-proofs in Full mode)
    let tmp_dir = tempfile::tempdir()?;
    let prove_start = Instant::now();

    let proof_path = tmp_dir.path().join("proof.bin");
    let prove_output = {
        let mut cmd = zisk_prove_cmd(cargo_zisk, elf_path, &proof_path,
                                      witness_lib.filter(|_| accepts_witness_lib),
                                      verify, is_gpu);
        cmd.output()?
    };
    let mut prove_duration = prove_start.elapsed();

    cleanup_stale_shm();
    if is_gpu {
        if !prove_output.status.success() {
            kill_cargo_zisk_processes();
        }
        wait_for_gpu_free(Duration::from_secs(30));
    }

    // Retry once on failure — cascading failures from stale GPU/shm state
    // are common, and the cleanup above usually fixes them.
    let final_output = if !prove_output.status.success() {
        // Check if this was a verify failure before retrying —
        // no point retrying a deterministic verification rejection.
        let combined = combined_output(&prove_output);
        if is_verify_failure(&combined) {
            prove_output
        } else {
            let stderr = String::from_utf8_lossy(&prove_output.stderr);
            let tail: String = stderr.lines().rev().take(10).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");
            eprintln!(
                "cargo-zisk prove failed for {} (retrying):\n{}",
                elf_path.display(),
                if tail.is_empty() { "(no stderr)".to_string() } else { tail },
            );

            let retry_start = Instant::now();
            let retry_output = {
                let mut cmd = zisk_prove_cmd(cargo_zisk, elf_path, &proof_path,
                                              witness_lib.filter(|_| accepts_witness_lib),
                                              verify, is_gpu);
                cmd.output()?
            };
            prove_duration += retry_start.elapsed();

            cleanup_stale_shm();
            if is_gpu {
                if !retry_output.status.success() {
                    kill_cargo_zisk_processes();
                }
                wait_for_gpu_free(Duration::from_secs(30));
            }

            if !retry_output.status.success() {
                let retry_stderr = String::from_utf8_lossy(&retry_output.stderr);
                let tail: String = retry_stderr.lines().rev().take(10).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");
                eprintln!(
                    "cargo-zisk prove failed for {} (retry also failed):\n{}",
                    elf_path.display(),
                    if tail.is_empty() { "(no stderr)".to_string() } else { tail },
                );
            }
            retry_output
        }
    } else {
        prove_output
    };

    if !final_output.status.success() {
        // Distinguish prove failure from verify failure by parsing output.
        // cargo-zisk logs "VERIFYING_PROOFS" and "was not verified" to stdout
        // when verification runs — if we see these, proving succeeded but
        // verification failed.
        let combined = combined_output(&final_output);
        return Ok(if is_verify_failure(&combined) {
            Proof::proved(prove_duration, false, Some(false))
        } else {
            Proof::failed(prove_duration)
        });
    }

    // Success — prove (and verify if requested) all passed
    let proof_written = proof_path.exists();

    Ok(Proof::proved(prove_duration, proof_written, verify.then_some(true)))
}

/// Parses the guest exit code from sp1-perf-executor's "exit code: N, cycles: M"
/// line. Upstream sp1-perf-executor always exits 0, so this line is the only
/// place where a failing ACT4 test (`a0 = 1` at halt) shows.
fn sp1_guest_exit_code(output: &str) -> Option<u32> {
    output.lines().find_map(|line| {
        let rest = line.trim().strip_prefix("exit code: ")?;
        rest.split(',').next()?.trim().parse().ok()
    })
}

/// Write an empty SP1Stdin (bincode): three zero-length fields = 24 zero bytes.
fn write_empty_sp1_stdin(dir: &Path) -> anyhow::Result<PathBuf> {
    let stdin_path = dir.join("stdin.bin");
    std::fs::write(&stdin_path, [0u8; 24])?;
    Ok(stdin_path)
}

/// SP1 execution: `sp1-perf-executor --program <elf> --param <stdin> --mode minimal --local`
/// — MinimalExecutor, propagates the guest exit code (0 = pass). SP1's JIT logs
/// "Unimplemented instruction" and continues with exit 0, so that string is also
/// treated as a failure. This step establishes the compliance pass/fail (the
/// prover ignores the guest exit code). `stdin` is an empty `SP1Stdin`.
fn run_sp1(executor: &Path, elf_path: &Path) -> Execution {
    let inner = || -> anyhow::Result<Execution> {
        let tmp_dir = tempfile::tempdir()?;
        let stdin_path = write_empty_sp1_stdin(tmp_dir.path())?;

        // Guest exit code + unimplemented-instruction check.
        let exec_output = Command::new(executor)
            .arg("--program")
            .arg(elf_path)
            .arg("--param")
            .arg(&stdin_path)
            .args(["--mode", "minimal", "--local"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()?;
        let exec_combined = combined_output(&exec_output);
        let passed = exec_output.status.success()
            && sp1_guest_exit_code(&exec_combined) == Some(0)
            && !exec_combined.to_lowercase().contains("unimplemented instruction");
        Ok(Execution::from_status(exec_output.status.code(), passed))
    };
    inner().unwrap_or_else(|e| runner_error(elf_path, e))
}

/// SP1 GPU prove+verify via the `sp1-perf` binary, after an execution that
/// passed (`run_sp1`): `sp1-perf --program <elf> --stdin <stdin> --mode cuda`
/// — executes, generates a core proof, and verifies it in one process (exit 0 =
/// prove and verify both succeeded). SP1 always verifies after proving, so prove
/// vs verify failure is distinguished by parsing the output: a `VerificationError`
/// means proving succeeded but verification failed.
///
/// `stdin` is an empty `SP1Stdin`. `--mode cuda` spawns the host-native
/// `sp1-gpu-server`; see prove_zisk for the analogous host-GPU serialization
/// (one prove at a time via jobs=1).
fn prove_sp1(sp1_perf: &Path, elf_path: &Path, verify: bool, gpu: bool) -> anyhow::Result<Proof> {
    let tmp_dir = tempfile::tempdir()?;
    let stdin_path = write_empty_sp1_stdin(tmp_dir.path())?;

    // Prove + verify (one process). GPU-only per project scope: `--mode cuda`
    // spawns the host-native sp1-gpu-server; `cpu` is a slow fallback.
    let prove_mode = if gpu { "cuda" } else { "cpu" };

    let prove_start = Instant::now();
    let mut prove_output = sp1_prove_cmd(sp1_perf, elf_path, &stdin_path, prove_mode).output()?;
    let mut prove_duration = prove_start.elapsed();

    if gpu {
        if !prove_output.status.success() {
            kill_sp1_gpu_processes();
        }
        wait_for_gpu_free(Duration::from_secs(30));
    }

    // Retry once on a non-verify failure — GPU/server transients are common,
    // while a deterministic verification rejection is not worth retrying.
    if !prove_output.status.success()
        && !is_sp1_verify_failure(&combined_output(&prove_output))
    {
        let stderr = String::from_utf8_lossy(&prove_output.stderr);
        let tail: String = stderr
            .lines()
            .rev()
            .take(8)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect::<Vec<_>>()
            .join("\n");
        eprintln!(
            "sp1-perf prove failed for {} (retrying):\n{}",
            elf_path.display(),
            if tail.is_empty() { "(no stderr)".to_string() } else { tail },
        );
        let retry_start = Instant::now();
        prove_output = sp1_prove_cmd(sp1_perf, elf_path, &stdin_path, prove_mode).output()?;
        prove_duration += retry_start.elapsed();
        if gpu {
            if !prove_output.status.success() {
                kill_sp1_gpu_processes();
            }
            wait_for_gpu_free(Duration::from_secs(30));
        }
    }

    if !prove_output.status.success() {
        let combined = combined_output(&prove_output);
        return Ok(if is_sp1_verify_failure(&combined) {
            Proof::proved(prove_duration, false, Some(false))
        } else {
            let tail: String = combined
                .lines()
                .rev()
                .take(8)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect::<Vec<_>>()
                .join("\n");
            eprintln!("sp1-perf prove failed for {}:\n{}", elf_path.display(), tail);
            Proof::failed(prove_duration)
        });
    }

    // Success — prove (and verify) passed.
    Ok(Proof::proved(prove_duration, true, verify.then_some(true)))
}

/// Build a `sp1-perf` execute+prove+verify command for the given prover mode.
fn sp1_prove_cmd(sp1_perf: &Path, elf_path: &Path, stdin_path: &Path, mode: &str) -> Command {
    let mut cmd = Command::new(sp1_perf);
    // Own process group + no core dumps, so a crashing gpu-server child can't
    // signal the runner or hang writing a multi-GB core.
    unsafe {
        cmd.pre_exec(|| {
            let zero = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
            libc::setrlimit(libc::RLIMIT_CORE, &zero);
            Ok(())
        });
    }
    cmd.process_group(0);
    cmd.arg("--program")
        .arg(elf_path)
        .arg("--stdin")
        .arg(stdin_path)
        .args(["--mode", mode]);
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    cmd
}

/// Whether a failed `sp1-perf` run indicates proving succeeded but verification
/// failed. `sp1-perf` verifies after proving and surfaces a `VerificationError`
/// (Display: "Failed to verify the proof") when the proof is rejected.
fn is_sp1_verify_failure(output: &str) -> bool {
    output.contains("VerificationError") || output.contains("Failed to verify the proof")
}

/// Kill any lingering sp1-gpu-server processes holding GPU memory. `sp1-perf`
/// kills its server on drop, but a crashed prove can leave one behind.
fn kill_sp1_gpu_processes() {
    let _ = Command::new("pkill")
        .args(["-9", "-f", "sp1-gpu-server"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    std::thread::sleep(Duration::from_secs(2));
}

/// Combine stdout and stderr into a single string for output parsing.
fn combined_output(output: &std::process::Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    format!("{stdout}{stderr}")
}

/// Check whether a failed `cargo-zisk prove --verify-proofs` output indicates
/// that proving succeeded but verification failed.
///
/// cargo-zisk logs verification activity to stdout:
///   ">>> VERIFYING_PROOFS"
///   "was not verified"
/// If either appears, the prover reached the verification stage (i.e. proving
/// itself succeeded).
fn is_verify_failure(output: &str) -> bool {
    output.contains("VERIFYING_PROOFS") || output.contains("was not verified")
}

/// Build a `cargo-zisk prove` command with standard flags.
///
/// `out_path` is the proof output **file** (v0.17.0+). `gpu` adds the explicit
/// `--gpu` flag to the cuda-built binary so it actually uses the GPU.
fn zisk_prove_cmd(
    cargo_zisk: &Path,
    elf_path: &Path,
    out_path: &Path,
    witness_lib: Option<&Path>,
    verify: bool,
    gpu: bool,
) -> Command {
    let mut cmd = Command::new(cargo_zisk);
    // Isolate in its own process group so MPI signal propagation
    // (e.g. SIGABRT from a crash) doesn't kill the parent runner.
    // Also disable core dumps — a crashing 7+ GB process would otherwise
    // hang for minutes writing a core via systemd-coredump.
    unsafe {
        cmd.pre_exec(|| {
            let zero = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
            libc::setrlimit(libc::RLIMIT_CORE, &zero);
            Ok(())
        });
    }
    cmd.process_group(0);
    cmd.args(["prove", "--elf"]).arg(elf_path);
    if let Some(wl) = witness_lib {
        cmd.arg("--witness-lib").arg(wl);
    }
    // v1.0.0 CLI: the Rust emulator is the default (the old `--emulator` flag is
    // gone; `--asm` now opts into the ASM emulator, which we don't want here).
    // `cargo-zisk prove` runs the per-program setup internally before proving.
    cmd.args(["-o"]).arg(out_path);
    if verify {
        // v1.0.0 renamed `--verify-proofs` → `--verify-proof`.
        cmd.arg("--verify-proof");
    }
    if gpu {
        cmd.arg("--gpu");
    }
    // Capture both stdout and stderr for output parsing
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    cmd
}

/// LambdaVM: a RV64IM STARK zkVM. The `lambdavm` CLI handles execution,
/// proving, and verification through subcommands.
///
/// Lifecycle:
/// 1. Execute: `lambdavm execute <elf>` — exit 0 = pass, non-zero = fault/panic
/// 2. Prove:   `lambdavm prove <elf> -o <proof>`
/// 3. Verify:  `lambdavm verify <proof> <elf>`
///
/// Compliance ELFs terminate via the Halt ecall (a7=93) for pass and the
/// Panic ecall (a7=2) for fail, so the executor's process exit code directly
/// reflects the test outcome. `LambdaVM::execute` runs step 1; this function
/// runs steps 2 and 3 after an execution that passed.
fn prove_lambdavm(binary: &Path, elf_path: &Path, verify: bool) -> anyhow::Result<Proof> {
    // 2. Prove
    let tmp_dir = tempfile::tempdir()?;
    let proof_path = tmp_dir.path().join("proof.bin");
    let prove_start = Instant::now();

    let prove_output = Command::new(binary)
        .args(["prove"])
        .arg(elf_path)
        .arg("-o")
        .arg(&proof_path)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()?;
    let prove_duration = prove_start.elapsed();

    if !prove_output.status.success() {
        let prove_stderr = String::from_utf8_lossy(&prove_output.stderr);
        eprintln!(
            "lambdavm prove failed for {}: {}",
            elf_path.display(),
            prove_stderr.lines().last().unwrap_or("(no output)"),
        );
        return Ok(Proof::failed(prove_duration));
    }

    let proof_written = proof_path.exists();

    // 3. Verify
    let verified = if verify {
        let verify_output = Command::new(binary)
            .args(["verify"])
            .arg(&proof_path)
            .arg(elf_path)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()?;

        if verify_output.status.success() {
            Some(true)
        } else {
            let verify_stderr = String::from_utf8_lossy(&verify_output.stderr);
            eprintln!(
                "lambdavm verify failed for {}: {}",
                elf_path.display(),
                verify_stderr.lines().last().unwrap_or("(no output)"),
            );
            Some(false)
        }
    } else {
        None
    };

    Ok(Proof::proved(prove_duration, proof_written, verified))
}

/// OpenVM: invoke `<binary> execute <elf_path>`.
///
/// The standalone runner exits 0 on a clean guest halt(0) and non-zero on any guest
/// failure (the SDK surfaces a non-zero guest exit code as an error).
fn run_openvm(binary: &Path, elf_path: &Path) -> Execution {
    let status = Command::new(binary)
        .arg("execute")
        .arg(elf_path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    match status {
        Ok(s) => Execution::from_status(s.code(), s.success()),
        Err(e) => Execution::host_error(None, format!("runner error: failed to run {}: {e}", binary.display())),
    }
}

/// OpenVM proving: a RV64IM continuation-STARK zkVM. The `openvm-binary` CLI handles
/// execution, app-level proving, and verification through subcommands.
///
/// Lifecycle:
/// 1. Execute: `openvm-binary execute <elf>`            — exit 0 = pass
/// 2. Prove:   `openvm-binary prove <elf> -o <proof>`   — app-level STARK proof
/// 3. Verify:  `openvm-binary verify <proof> <elf>`
///
/// When the binary is built with the `cuda` feature, proving and verification run on
/// the GPU. We serialize GPU work (the runner defaults prove/full to one job) and wait
/// for the GPU to drain between tests, killing any stuck process after a failed prove —
/// mirroring prove_zisk's GPU hygiene. `run_openvm` runs step 1; this function
/// runs steps 2 and 3 after an execution that passed.
fn prove_openvm(binary: &Path, elf_path: &Path, verify: bool, gpu: bool) -> anyhow::Result<Proof> {
    // 2. Prove
    let tmp_dir = tempfile::tempdir()?;
    let proof_path = tmp_dir.path().join("proof.bin");
    let prove_start = Instant::now();

    let prove_output = openvm_cmd(binary)
        .args(["prove"])
        .arg(elf_path)
        .arg("-o")
        .arg(&proof_path)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()?;
    let prove_duration = prove_start.elapsed();

    if gpu {
        if !prove_output.status.success() {
            kill_openvm_processes();
        }
        wait_for_gpu_free(Duration::from_secs(30));
    }

    if !prove_output.status.success() {
        let prove_stderr = String::from_utf8_lossy(&prove_output.stderr);
        eprintln!(
            "openvm prove failed for {}: {}",
            elf_path.display(),
            prove_stderr.lines().last().unwrap_or("(no output)"),
        );
        return Ok(Proof::failed(prove_duration));
    }

    let proof_written = proof_path.exists();

    // 3. Verify
    let verified = if verify {
        let verify_output = openvm_cmd(binary)
            .args(["verify"])
            .arg(&proof_path)
            .arg(elf_path)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()?;

        if gpu {
            wait_for_gpu_free(Duration::from_secs(30));
        }

        if verify_output.status.success() {
            Some(true)
        } else {
            let verify_stderr = String::from_utf8_lossy(&verify_output.stderr);
            eprintln!(
                "openvm verify failed for {}: {}",
                elf_path.display(),
                verify_stderr.lines().last().unwrap_or("(no output)"),
            );
            Some(false)
        }
    } else {
        None
    };

    Ok(Proof::proved(prove_duration, proof_written, verified))
}

/// Build an `openvm-binary` command isolated in its own process group with core dumps
/// disabled — a GPU prover crash would otherwise risk killing the parent runner and
/// spend minutes writing a multi-GB core via systemd-coredump.
fn openvm_cmd(binary: &Path) -> Command {
    let mut cmd = Command::new(binary);
    unsafe {
        cmd.pre_exec(|| {
            let zero = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
            libc::setrlimit(libc::RLIMIT_CORE, &zero);
            Ok(())
        });
    }
    cmd.process_group(0);
    cmd
}

/// Kill any lingering openvm-binary processes that may be holding GPU memory.
fn kill_openvm_processes() {
    let _ = Command::new("pkill")
        .args(["-9", "openvm-binary"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    std::thread::sleep(Duration::from_secs(3));
}

/// Encode input for ziskemu: one record of `[u64 LE length][data, zero-padded to 8 bytes]`.
fn zisk_frame_input(data: &[u8]) -> Vec<u8> {
    let mut framed = Vec::with_capacity(8 + data.len() + 7);
    framed.extend_from_slice(&(data.len() as u64).to_le_bytes());
    framed.extend_from_slice(data);
    framed.resize(framed.len().next_multiple_of(8), 0);
    framed
}

/// Pick the most informative stderr line: the message of a Rust panic when
/// the emulator panicked, else the last line that is not a `note:`.
fn emulator_error_reason(stderr: &str) -> String {
    let lines: Vec<&str> = stderr.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    if let Some(i) = lines.iter().position(|l| l.contains("panicked at")) {
        if let Some(message) = lines.get(i + 1) {
            return (*message).to_owned();
        }
    }
    lines
        .iter()
        .rev()
        .find(|l| !l.starts_with("note:"))
        .map(|l| (*l).to_owned())
        .unwrap_or_default()
}

/// Whether `ziskemu`'s stderr shows that it rejected the guest's execution:
/// a memory access outside the guest's sections (`core/src/mem.rs`), a jump
/// outside the program (`core/src/zisk_rom.rs`), or an emulation that
/// "finished with error". Any other failure (a file that is not an ELF, a
/// loader or usage error) happened before the guest ran.
fn zisk_guest_fault(stderr: &str) -> bool {
    stderr.contains("invalid addr") || stderr.contains("is out of range") || stderr.contains("finished with error")
}

/// Zisk: invoke `<binary> -e <elf_path> -o <file>`, with `-i` (the framed input)
/// when the test has an input vector.
///
/// Termination:
/// - ZisK reports no error code: ZisK >= 1.2 ignores `a0` at the exit ecall.
///   A guest fault on stderr (`zisk_guest_fault`; "finished with error" can
///   come with exit 0) means that ZisK rejected the execution, so the guest
///   terminated abnormally without a code. A non-zero exit without a guest
///   fault is a host error.
/// - The ZisK ACT4 halt macros write `PASS` or `FAIL` to public output 0
///   (zkvms/zisk/isa-configs/*/rvmodel_macros.h). `FAIL` is an abnormal
///   termination, and `PASS` shows the pass halt. Without a marker, the guest
///   returned from `main` or exited: a successful termination without the
///   pass halt.
/// - ZisK's public output is a fixed area of 64 u32 words with zero padding.
/// - A spawn failure, a missing output file or a death by signal is a host error.
fn run_zisk(binary: &Path, elf_path: &Path, input: Option<&[u8]>) -> Execution {
    let inner = || -> anyhow::Result<Execution> {
        let tmp = tempfile::tempdir().context("failed to create temp dir")?;
        let input_path = tmp.path().join("input.bin");
        let output_path = tmp.path().join("output.bin");

        let mut cmd = Command::new(binary);
        cmd.arg("-e").arg(elf_path);
        if let Some(input) = input {
            std::fs::write(&input_path, zisk_frame_input(input))?;
            cmd.arg("-i").arg(&input_path);
        }
        cmd.arg("-o").arg(&output_path);
        let output = cmd
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .with_context(|| format!("failed to run {}", binary.display()))?;

        let exit_code = output.status.code();
        let stderr = String::from_utf8_lossy(&output.stderr);
        let reason = emulator_error_reason(&stderr);
        if exit_code.is_none() {
            let detail = format!("emulator killed by a signal: {reason}");
            return Ok(Execution::host_error(exit_code, detail));
        }
        if !output.status.success() || stderr.contains("finished with error") {
            let detail = format!("emulator error (exit {}): {reason}", exit_text(exit_code));
            if !zisk_guest_fault(&stderr) {
                return Ok(Execution::host_error(exit_code, detail));
            }
            return Ok(Execution::failure(exit_code, None, detail));
        }

        let Ok(actual) = std::fs::read(&output_path) else {
            return Ok(Execution::host_error(exit_code, "emulator wrote no output file".to_owned()));
        };
        if actual.starts_with(b"FAIL") {
            return Ok(Execution::failure(exit_code, None, "public output has the FAIL marker".to_owned()));
        }
        let pass_halt = if actual.starts_with(b"PASS") {
            PassHalt::Reached
        } else {
            PassHalt::Missed("public output does not start with the PASS marker".to_owned())
        };
        let output = PublicOutput { bytes: actual, area: OutputArea::ZeroPadded };
        Ok(Execution::success(exit_code, output, pass_halt))
    };
    inner().unwrap_or_else(|e| Execution::host_error(None, format!("runner error: {e:#}")))
}

/// How a zkVM's public output compares with the expected bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutputArea {
    /// A variable-length stream (SP1): the output must equal the expected bytes.
    Exact,
    /// A fixed area with zero padding (OpenVM with ere's VM config: 256 bytes;
    /// ZisK: 64 u32 words).
    ZeroPadded,
}

impl PublicOutput {
    /// Why the output does not match `expected`, or `None` if it does.
    pub fn mismatch(&self, expected: &[u8]) -> Option<String> {
        let actual = &self.bytes;
        match self.area {
            OutputArea::Exact => (actual != expected).then(|| io_and_expected_failures::describe_exact_mismatch(actual, expected)),
            OutputArea::ZeroPadded => {
                (!io_and_expected_failures::matches_zero_padded(actual, expected)).then(|| io_and_expected_failures::describe_mismatch(actual, expected))
            }
        }
    }
}

/// Run a guest through an eth-act standards executor:
/// `<executor> <elf> <input file> <public output file> <exit code file>`.
///
/// `sp1-eth-act-standards-executor` pushes the input as one SP1 stdin chunk;
/// `openvm-eth-act-standards-executor` passes it as one OpenVM input vector.
/// Both write the raw public values. The exit status is the guest's
/// termination:
/// - 0: the guest terminated successfully;
/// - 1: the guest terminated abnormally. The executor writes the guest's
///   error code (decimal) to the exit code file when the zkVM reports it;
/// - anything else, or a death by signal: a host error.
fn run_io_executor(executor: &Path, elf_path: &Path, input: Option<&[u8]>, area: OutputArea) -> Execution {
    let inner = || -> anyhow::Result<Execution> {
        let tmp = tempfile::tempdir().context("failed to create temp dir")?;
        let input_path = tmp.path().join("input.bin");
        let output_path = tmp.path().join("public-values.bin");
        let code_path = tmp.path().join("exit-code.txt");
        std::fs::write(&input_path, input.unwrap_or_default())?;

        let output = Command::new(executor)
            .arg(elf_path)
            .arg(&input_path)
            .arg(&output_path)
            .arg(&code_path)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .with_context(|| format!("failed to run {}", executor.display()))?;

        let exit_code = output.status.code();
        let reason = emulator_error_reason(&String::from_utf8_lossy(&output.stderr));
        match exit_code {
            Some(0) => {}
            Some(1) => {
                let code = match std::fs::read_to_string(&code_path) {
                    Ok(text) => match parse_error_code(&text) {
                        Some(code) => Some(code),
                        None => {
                            let detail = format!("executor wrote an invalid exit code {:?}", text.trim());
                            return Ok(Execution::host_error(exit_code, detail));
                        }
                    },
                    Err(_) => None,
                };
                let code_text = code.map_or_else(|| "no error code".to_owned(), |c| format!("error code {c}"));
                let detail = format!("guest terminated abnormally ({code_text}): {reason}");
                return Ok(Execution::failure(exit_code, code, detail));
            }
            _ => {
                let detail = format!("executor error (exit {}): {reason}", exit_text(exit_code));
                return Ok(Execution::host_error(exit_code, detail));
            }
        }

        // The pass halt is exit code 0, which a return from main also gives, so
        // the pass halt is unknown (see `runner::judge`).
        let Ok(actual) = std::fs::read(&output_path) else {
            return Ok(Execution::host_error(exit_code, "executor wrote no public values".to_owned()));
        };
        Ok(Execution::success(exit_code, PublicOutput { bytes: actual, area }, PassHalt::Unknown))
    };
    inner().unwrap_or_else(|e| Execution::host_error(None, format!("runner error: {e:#}")))
}

/// Parse a guest error code: a decimal `i32`, or a `u32` exit code (a register
/// value, so 4294967295 is -1).
fn parse_error_code(text: &str) -> Option<i32> {
    let text = text.trim();
    text.parse::<i32>().ok().or_else(|| text.parse::<u32>().ok().map(|c| c as i32))
}

/// An exit code for a failure detail: the number, or "signal".
fn exit_text(exit_code: Option<i32>) -> String {
    exit_code.map_or_else(|| "signal".to_owned(), |c| c.to_string())
}

/// Kill any lingering cargo-zisk processes that may be holding GPU memory.
fn kill_cargo_zisk_processes() {
    let _ = Command::new("pkill")
        .args(["-9", "cargo-zisk"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    std::thread::sleep(Duration::from_secs(3));
}

/// Remove stale shared memory files left by dead cargo-zisk child processes.
///
/// OpenMP leaves `__KMP_REGISTERED_LIB_<pid>_*` and MPI leaves `sem.mp-*` files
/// in /dev/shm. If the owning process crashed, these persist and can cause
/// subsequent proves to fail or hang. We only remove files whose owning PID
/// is no longer running.
fn cleanup_stale_shm() {
    let entries = match std::fs::read_dir("/dev/shm") {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();

        // Only clean up files from cargo-zisk: OpenMP KMP libs and MPI semaphores
        if name.starts_with("__KMP_REGISTERED_LIB_") {
            // Format: __KMP_REGISTERED_LIB_<pid>_<uid>
            if let Some(pid_str) = name.strip_prefix("__KMP_REGISTERED_LIB_") {
                if let Some(pid_str) = pid_str.split('_').next() {
                    if let Ok(pid) = pid_str.parse::<i32>() {
                        // Check if PID is still alive
                        if unsafe { libc::kill(pid, 0) } != 0 {
                            let _ = std::fs::remove_file(entry.path());
                        }
                    }
                }
            }
        } else if name.starts_with("sem.mp-") {
            // MPI semaphores don't encode PID — remove if no cargo-zisk is running
            let has_cargo_zisk = Command::new("pgrep")
                .arg("cargo-zisk")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if !has_cargo_zisk {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

/// Wait until no GPU compute processes are running (via nvidia-smi).
/// This prevents back-to-back GPU proving from failing because the previous
/// process hasn't fully released GPU memory yet.
fn wait_for_gpu_free(timeout: Duration) {
    let start = Instant::now();
    loop {
        let output = Command::new("nvidia-smi")
            .args(["--query-compute-apps=pid", "--format=csv,noheader"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output();

        match output {
            Ok(o) if o.status.success() => {
                let stdout = String::from_utf8_lossy(&o.stdout);
                if stdout.trim().is_empty() {
                    return; // GPU is free
                }
            }
            _ => return, // nvidia-smi not available, skip wait
        }

        if start.elapsed() > timeout {
            eprintln!("warning: GPU not free after {timeout:?}, proceeding anyway");
            return;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Mutex;

    use super::*;
    use crate::runner::{self, Suite};

    /// Serializes the tests that write and spawn fake executors: a script
    /// that another thread's fork holds open for writing fails with ETXTBSY.
    static SPAWN: Mutex<()> = Mutex::new(());

    /// Judge an execution of a standards test, which has an (empty) input.
    fn judged(execution: Execution, expected: Option<&[u8]>) -> RunResult {
        runner::judge(execution, expected, true, Instant::now())
    }

    /// Write an executable shell script with `body` and return its path.
    fn fake(dir: &Path, name: &str, body: &str) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    /// Run a fake standards executor (`$3` is the public output file, `$4`
    /// the exit code file).
    fn io_executor(body: &str, expected: Option<&[u8]>) -> RunResult {
        let _guard = SPAWN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let executor = fake(dir.path(), "executor", body);
        let elf = dir.path().join("t.elf");
        judged(run_io_executor(&executor, &elf, Some(&[]), OutputArea::Exact), expected)
    }

    /// Run a fake `ziskemu` (the last argument is the output file).
    fn ziskemu(body: &str, expected: Option<&[u8]>) -> RunResult {
        let _guard = SPAWN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let emulator = fake(dir.path(), "ziskemu", &format!("for out; do :; done\n{body}"));
        let elf = dir.path().join("t.elf");
        judged(run_zisk(&emulator, &elf, Some(&[])), expected)
    }

    fn failure(code: Option<i32>) -> Termination {
        Termination::Failure { code }
    }

    #[test]
    fn io_executor_success() {
        let r = io_executor("printf PASS > \"$3\"; echo 0 > \"$4\"", None);
        assert_eq!(r.termination, Termination::Success);
        assert!(r.passed);

        // A return from main without the PASS verdict.
        let r = io_executor(": > \"$3\"", None);
        assert_eq!(r.termination, Termination::Success);
        assert!(!r.passed);

        let r = io_executor("printf abc > \"$3\"", Some(b"abc"));
        assert_eq!(r.termination, Termination::Success);
        assert!(r.passed);
    }

    #[test]
    fn io_executor_failure_with_and_without_a_code() {
        let r = io_executor("echo 7 > \"$4\"; echo 'guest halted with exit code 7' >&2; exit 1", None);
        assert_eq!(r.termination, failure(Some(7)));
        assert!(!r.passed);
        assert_eq!(
            r.detail.as_deref(),
            Some("guest terminated abnormally (error code 7): guest halted with exit code 7")
        );

        let r = io_executor("echo 4294967295 > \"$4\"; exit 1", None);
        assert_eq!(r.termination, failure(Some(-1)));

        let r = io_executor("echo 'invalid memory access' >&2; exit 1", None);
        assert_eq!(r.termination, failure(None));
        assert_eq!(
            r.detail.as_deref(),
            Some("guest terminated abnormally (no error code): invalid memory access")
        );
    }

    #[test]
    fn io_executor_host_errors() {
        // Usage, I/O or executor errors.
        let r = io_executor("echo 'error: read input' >&2; exit 2", None);
        assert_eq!(r.termination, Termination::HostError);
        assert_eq!(r.detail.as_deref(), Some("executor error (exit 2): error: read input"));

        // Any other status, e.g. a Rust panic of the executor.
        let r = io_executor("exit 101", None);
        assert_eq!(r.termination, Termination::HostError);

        // Killed by a signal.
        let r = io_executor("kill -9 $$", None);
        assert_eq!(r.termination, Termination::HostError);
        assert_eq!(r.exit_code, None);
        assert!(r.detail.unwrap().starts_with("executor error (exit signal)"));

        // Success without public values.
        let r = io_executor("exit 0", None);
        assert_eq!(r.termination, Termination::HostError);
        assert_eq!(r.detail.as_deref(), Some("executor wrote no public values"));

        // An exit code file that is not a number.
        let r = io_executor("echo seven > \"$4\"; exit 1", None);
        assert_eq!(r.termination, Termination::HostError);

        // The executor does not exist.
        let _guard = SPAWN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("missing");
        let r = judged(run_io_executor(&missing, &missing, Some(&[]), OutputArea::Exact), None);
        assert_eq!(r.termination, Termination::HostError);
        assert!(r.detail.unwrap().starts_with("runner error: failed to run"));
    }

    #[test]
    fn zisk_success_and_act4_verdict() {
        let r = ziskemu("printf 'PASS\\000\\000\\000\\000' > \"$out\"", None);
        assert_eq!(r.termination, Termination::Success);
        assert!(r.passed);

        let r = ziskemu("printf 'FAIL' > \"$out\"", None);
        assert_eq!(r.termination, failure(None));
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("public output has the FAIL marker"));

        // A return from main: ZisK ignores its value, so this is a success
        // without the PASS verdict.
        let r = ziskemu("printf '\\000\\000\\000\\000' > \"$out\"", None);
        assert_eq!(r.termination, Termination::Success);
        assert_eq!(r.detail.as_deref(), Some("public output does not start with the PASS marker"));

        let r = ziskemu("printf 'ab\\000\\000' > \"$out\"", Some(b"ab"));
        assert_eq!(r.termination, Termination::Success);
        assert!(r.passed);
    }

    #[test]
    fn zisk_rejected_execution_is_a_failure_without_a_code() {
        let r = ziskemu(
            "echo \"thread 'main' panicked at mem.rs:1:1:\" >&2; echo 'invalid addr' >&2; exit 101",
            None,
        );
        assert_eq!(r.termination, failure(None));
        assert_eq!(r.detail.as_deref(), Some("emulator error (exit 101): invalid addr"));

        let r = ziskemu("printf PASS > \"$out\"; echo 'Emulation finished with error' >&2", None);
        assert_eq!(r.termination, failure(None));
        assert_eq!(r.exit_code, Some(0));
    }

    #[test]
    fn zisk_host_errors() {
        // Failures before the guest runs: not an ELF, a loader error.
        let r = ziskemu(
            "echo 'Error during emulation: Unknown(\"ROM file is not a valid ELF file\")' >&2; exit 1",
            None,
        );
        assert_eq!(r.termination, Termination::HostError);
        let r = ziskemu("echo 'error while loading shared libraries: libmissing.so' >&2; exit 127", None);
        assert_eq!(r.termination, Termination::HostError);
        assert_eq!(r.exit_code, Some(127));

        let r = ziskemu("kill -9 $$", None);
        assert_eq!(r.termination, Termination::HostError);
        assert!(r.detail.unwrap().starts_with("emulator killed by a signal"));

        let r = ziskemu("exit 0", None);
        assert_eq!(r.termination, Termination::HostError);
        assert_eq!(r.detail.as_deref(), Some("emulator wrote no output file"));

        let _guard = SPAWN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("missing");
        let r = judged(run_zisk(&missing, &missing, Some(&[])), None);
        assert_eq!(r.termination, Termination::HostError);
    }

    #[test]
    fn expected_outcome_through_a_fake_executor() {
        let _guard = SPAWN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let elf = dir.path().join("t.elf");
        std::fs::write(&elf, b"").unwrap();
        let run = |body: &str, outcome: &str| {
            std::fs::write(dir.path().join("t.outcome"), outcome).unwrap();
            let executor = fake(dir.path(), &format!("executor-{}", body.len()), body);
            let sp1 = Sp1 { executor: Executor::Io(executor), sp1_perf: None, gpu: false };
            runner::run_one(&sp1, Suite::Standards, &elf, Mode::Execute)
        };

        let r = run("echo 7 > \"$4\"; exit 1", "fail 7\n");
        assert!(r.passed);

        let r = run("echo 7 > \"$4\"; exit 1", "fail 1\n");
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("wrong error code: expected 1, got 7"));

        // A host error does not count as a panic.
        let r = run("echo 'error: usage' >&2; exit 2", "fail\n");
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("executor error (exit 2): error: usage"));
    }

    #[test]
    fn zisk_panic_test_needs_a_guest_fault() {
        let _guard = SPAWN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let elf = dir.path().join("t.elf");
        std::fs::write(&elf, b"").unwrap();
        std::fs::write(dir.path().join("t.outcome"), "fail\n").unwrap();
        let run = |body: &str| {
            let binary = fake(dir.path(), &format!("ziskemu-{}", body.len()), body);
            let zisk = Zisk { ziskemu: binary, cargo_zisk: None, witness_lib: None };
            runner::run_one(&zisk, Suite::Standards, &elf, Mode::Execute)
        };

        let fault = "echo \"thread 'main' panicked at core/src/mem.rs:669:13:\" >&2
            echo 'Mem::write_silent() invalid addr=0=0 write section start=a0000000 end=c0000000' >&2
            exit 101";
        assert!(run(fault).passed);

        let not_an_elf = "echo 'Error during emulation: Unknown(\"ROM file is not a valid ELF file\")' >&2; exit 1";
        assert!(!run(not_an_elf).passed);
        let loader = "echo 'error while loading shared libraries: libmissing.so' >&2; exit 127";
        assert!(!run(loader).passed);
    }

    #[test]
    fn parses_error_codes() {
        assert_eq!(parse_error_code("7\n"), Some(7));
        assert_eq!(parse_error_code("-1"), Some(-1));
        assert_eq!(parse_error_code("4294967295"), Some(-1));
        assert_eq!(parse_error_code(""), None);
        assert_eq!(parse_error_code("x"), None);
    }

    #[test]
    fn parses_sp1_guest_exit_code() {
        let pass = "MinimalExecutor creation time: 1ms\nexit code: 0, cycles: 4321\n";
        let fail = "exit code: 1, cycles: 12\nexecution time: 2ms\n";
        assert_eq!(sp1_guest_exit_code(pass), Some(0));
        assert_eq!(sp1_guest_exit_code(fail), Some(1));
        assert_eq!(sp1_guest_exit_code("no such line\n"), None);
    }

    fn binary() -> Tools {
        Tools { binary: Some(PathBuf::from("bin")), ..Tools::default() }
    }

    fn io_exec() -> Tools {
        Tools { io_executor: Some(PathBuf::from("exec")), ..Tools::default() }
    }

    #[test]
    fn builds_each_zkvm_from_its_name() {
        for name in ZKVMS {
            let zkvm = build(name, binary()).unwrap();
            assert_eq!(zkvm.name(), name);
            // Only ziskemu takes an input among the zkVMs' own executors.
            assert_eq!(zkvm.supports_io(), name == "zisk", "{name}");
            // lambdavm and openvm-binary also prove; sp1 and zisk need their prover tools.
            assert_eq!(zkvm.can_prove(), matches!(name, "lambdavm" | "openvm"), "{name}");
        }

        // An eth-act standards executor takes an input, but does not prove.
        for name in ["openvm", "sp1"] {
            let zkvm = build(name, io_exec()).unwrap();
            assert_eq!(zkvm.name(), name);
            assert!(zkvm.supports_io(), "{name}");
            assert!(!zkvm.can_prove(), "{name}");
        }

        let sp1 = build("sp1", Tools { sp1_perf: Some(PathBuf::from("sp1-perf")), ..binary() }).unwrap();
        assert!(sp1.can_prove());
        let zisk = build("zisk", Tools { cargo_zisk: Some(PathBuf::from("cargo-zisk")), ..binary() }).unwrap();
        assert!(zisk.can_prove());
    }

    #[test]
    fn rejects_unknown_names_and_missing_tools() {
        // The old per-suite and per-mode names are gone.
        for name in ["sp1-prove", "zisk-prove", "openvm-prove", "zisk-standards", "sp1-standards", "risc0", ""] {
            let e = build(name, binary()).err().unwrap();
            assert!(e.to_string().starts_with(&format!("unknown zkvm '{name}'")), "{e}");
        }
        for name in ZKVMS {
            assert!(build(name, Tools::default()).is_err(), "{name}");
            let both = Tools { binary: Some(PathBuf::from("bin")), ..io_exec() };
            assert!(build(name, both).is_err(), "{name}");
        }
        // Only openvm and sp1 have an eth-act standards executor.
        assert!(build("lambdavm", io_exec()).is_err());
        assert!(build("zisk", io_exec()).is_err());
    }

    #[test]
    fn prove_without_prover_tools_is_an_error() {
        let _guard = SPAWN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let elf = dir.path().join("t.elf");
        for (name, tools) in [("sp1", binary()), ("zisk", binary()), ("openvm", io_exec()), ("sp1", io_exec())] {
            let zkvm = build(name, tools).unwrap();
            assert!(zkvm.prove(&elf, None, true).is_err(), "{name}");
            assert!(runner::check_mode(&*zkvm, Mode::Prove).is_err(), "{name}");
            assert!(runner::check_mode(&*zkvm, Mode::Full).is_err(), "{name}");
            assert!(runner::check_mode(&*zkvm, Mode::Execute).is_ok(), "{name}");
        }
        // The provers take no input.
        let zisk = build("zisk", Tools { cargo_zisk: Some(dir.path().join("cargo-zisk")), ..binary() }).unwrap();
        let e = zisk.prove(&elf, Some(&[]), false).err().unwrap();
        assert_eq!(e.to_string(), "the zisk prover cannot take an input");
    }

    #[test]
    fn sp1_cli_executor_reports_the_guest_exit_code() {
        let _guard = SPAWN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let elf = dir.path().join("t.elf");
        let run = |body: &str| {
            let executor = fake(dir.path(), &format!("sp1-{}", body.len()), body);
            let execution = Sp1 { executor: Executor::Cli(executor), sp1_perf: None, gpu: false }.execute(&elf, None);
            runner::judge(execution, None, false, Instant::now())
        };

        let r = run("echo 'exit code: 0, cycles: 12'");
        assert_eq!(r.termination, Termination::Success);
        assert!(r.passed);

        // sp1-perf-executor exits 0 when the guest fails.
        let r = run("echo 'exit code: 1, cycles: 12'");
        assert_eq!(r.termination, failure(None));
        assert!(!r.passed);

        let r = run("echo 'exit code: 0, cycles: 12'; echo 'Unimplemented instruction' >&2");
        assert!(!r.passed);
    }

    #[test]
    fn zisk_isa_test_needs_the_pass_marker() {
        let _guard = SPAWN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let elf = dir.path().join("t.elf");
        let run = |body: &str| {
            let emulator = fake(dir.path(), &format!("ziskemu-{}", body.len()), &format!("for out; do :; done\n{body}"));
            let execution = Zisk { ziskemu: emulator, cargo_zisk: None, witness_lib: None }.execute(&elf, None);
            runner::judge(execution, None, false, Instant::now())
        };

        let r = run("printf 'PASS\\000\\000\\000\\000' > \"$out\"");
        assert!(r.passed);

        let r = run("printf 'FAIL' > \"$out\"");
        assert_eq!(r.termination, failure(None));
        assert_eq!(r.detail.as_deref(), Some("public output has the FAIL marker"));

        let r = run("printf '\\000\\000\\000\\000' > \"$out\"");
        assert_eq!(r.termination, Termination::Success);
        assert_eq!(r.detail.as_deref(), Some("public output does not start with the PASS marker"));
    }

    #[test]
    fn picks_panic_message_from_stderr() {
        let stderr = "thread 'main' panicked at core/src/zisk_rom.rs:367:21:\n\
                      pc=0x80001BC0 is out of range\n\
                      note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n";
        assert_eq!(emulator_error_reason(stderr), "pc=0x80001BC0 is out of range");
        assert_eq!(emulator_error_reason("boom\nnote: hint\n"), "boom");
    }

    #[test]
    fn frames_input_with_length_and_padding() {
        assert_eq!(zisk_frame_input(&[]), vec![0; 8]);
        let framed = zisk_frame_input(b"abc");
        assert_eq!(framed.len(), 16);
        assert_eq!(&framed[..8], &3u64.to_le_bytes());
        assert_eq!(&framed[8..11], b"abc");
        assert!(framed[11..].iter().all(|&b| b == 0));
        assert_eq!(zisk_frame_input(&[7; 8]).len(), 16);
    }
}
