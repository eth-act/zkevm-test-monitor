use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::Context;

use crate::io::{self, IoVectors};

/// Supported ZK-VMs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Zkvm {
    LambdaVM,
    OpenVM,
    Sp1,
    Zisk,
}

/// Test suites a backend can run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Suite {
    /// The ACT4 ISA tests: pass = clean exit, optionally prove and verify.
    Isa,
    /// The eth-act standards tests: check the guest's public output.
    Standards,
}

/// A ZK-VM backend: the zkVM, the suite it runs and, for the prove
/// backends, the prover.
///
/// Build it with `Backend::new`, which rejects unsupported combinations.
pub struct Backend {
    pub zkvm: Zkvm,
    pub suite: Suite,
    /// The emulator or executor that runs the ELF.
    pub binary: PathBuf,
    /// The prover; `None` = execute only.
    pub prove: Option<Prover>,
}

/// The prover of a prove backend. `Mode` decides whether it proves and
/// verifies.
pub struct Prover {
    pub gpu: bool,
    pub tools: ProverTools,
}

/// The extra tools each prover needs besides `Backend::binary`.
pub enum ProverTools {
    /// `sp1-perf` proves and verifies.
    Sp1 { sp1_perf: PathBuf },
    /// `Backend::binary` also proves and verifies.
    OpenVM,
    /// `cargo-zisk` proves and verifies.
    Zisk { cargo_zisk: PathBuf, witness_lib: Option<PathBuf> },
}

impl Zkvm {
    /// The zkVM's name, the stem of its `--zkvm` names.
    pub fn name(self) -> &'static str {
        match self {
            Zkvm::LambdaVM => "lambdavm",
            Zkvm::OpenVM => "openvm",
            Zkvm::Sp1 => "sp1",
            Zkvm::Zisk => "zisk",
        }
    }

    fn from_name(name: &str) -> Option<Self> {
        [Zkvm::LambdaVM, Zkvm::OpenVM, Zkvm::Sp1, Zkvm::Zisk].into_iter().find(|z| z.name() == name)
    }
}

impl ProverTools {
    fn zkvm(&self) -> Zkvm {
        match self {
            ProverTools::Sp1 { .. } => Zkvm::Sp1,
            ProverTools::OpenVM => Zkvm::OpenVM,
            ProverTools::Zisk { .. } => Zkvm::Zisk,
        }
    }
}

/// Whether a backend exists for this zkVM, suite and prover presence.
fn is_supported(zkvm: Zkvm, suite: Suite, prove: bool) -> bool {
    match (zkvm, suite, prove) {
        (Zkvm::LambdaVM | Zkvm::OpenVM | Zkvm::Zisk, Suite::Isa, false) => true,
        (Zkvm::OpenVM | Zkvm::Sp1 | Zkvm::Zisk, Suite::Isa, true) => true,
        (Zkvm::OpenVM | Zkvm::Sp1 | Zkvm::Zisk, Suite::Standards, false) => true,
        _ => false,
    }
}

/// Parse a `--zkvm` name into its zkVM, suite and whether it proves.
/// Returns `None` for an unknown name or an unsupported combination.
pub fn parse_name(name: &str) -> Option<(Zkvm, Suite, bool)> {
    let (stem, suite, prove) = if let Some(stem) = name.strip_suffix("-standards") {
        (stem, Suite::Standards, false)
    } else if let Some(stem) = name.strip_suffix("-prove") {
        (stem, Suite::Isa, true)
    } else {
        (name, Suite::Isa, false)
    };
    let zkvm = Zkvm::from_name(stem)?;
    is_supported(zkvm, suite, prove).then_some((zkvm, suite, prove))
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
    fn executed(
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
}

impl Backend {
    /// Build a backend. Fails for an unsupported combination, or when the
    /// prover tools belong to another zkVM.
    pub fn new(zkvm: Zkvm, suite: Suite, binary: PathBuf, prove: Option<Prover>) -> anyhow::Result<Self> {
        if !is_supported(zkvm, suite, prove.is_some()) {
            let what = if prove.is_some() { "a prover" } else { "an executor" };
            anyhow::bail!("{} has no {suite:?} backend with {what}", zkvm.name());
        }
        if let Some(prover) = &prove {
            if prover.tools.zkvm() != zkvm {
                anyhow::bail!("{} prover tools given for {}", prover.tools.zkvm().name(), zkvm.name());
            }
        }
        Ok(Backend { zkvm, suite, binary, prove })
    }

    /// The backend's name for `--zkvm`.
    pub fn name(&self) -> String {
        match (self.suite, &self.prove) {
            (Suite::Standards, _) => format!("{}-standards", self.zkvm.name()),
            (Suite::Isa, Some(_)) => format!("{}-prove", self.zkvm.name()),
            (Suite::Isa, None) => self.zkvm.name().to_owned(),
        }
    }

    /// Whether this backend runs the eth-act standards tests. Their guests
    /// default to an empty input and the expected output `PASS`.
    pub fn is_standards(&self) -> bool {
        self.suite == Suite::Standards
    }

    /// Whether this backend can feed `.input` and check `.expected`.
    fn supports_io(&self) -> bool {
        self.is_standards() || (self.zkvm == Zkvm::Zisk && self.prove.is_none())
    }

    /// Execute an ELF test through the backend and return the result.
    ///
    /// For most backends, `mode` is ignored (execute-only). The prove
    /// backends use `mode` to control whether to prove
    /// and/or verify.
    pub fn run_elf(&self, elf_path: &Path, mode: Mode, vectors: &IoVectors) -> RunResult {
        let start = Instant::now();

        if vectors.has_io() && !self.supports_io() {
            return RunResult::host_error(
                start,
                None,
                format!("the {} backend cannot feed .input or check .expected", self.name()),
            );
        }

        let binary = &self.binary;
        match (self.zkvm, self.suite, &self.prove) {
            (Zkvm::LambdaVM, Suite::Isa, None) => {
                run_lambdavm(binary, elf_path, mode, start)
            }
            (Zkvm::Sp1, Suite::Isa, Some(Prover { gpu, tools: ProverTools::Sp1 { sp1_perf } })) => {
                run_sp1_prove(binary, sp1_perf, elf_path, mode, *gpu, start)
            }
            (Zkvm::OpenVM, Suite::Isa, Some(Prover { gpu, tools: ProverTools::OpenVM })) => {
                run_openvm_prove(binary, elf_path, mode, *gpu, start)
            }
            (Zkvm::Zisk, Suite::Isa, Some(Prover { gpu, tools: ProverTools::Zisk { cargo_zisk, witness_lib } })) => {
                run_zisk_prove(binary, cargo_zisk, witness_lib.as_deref(), elf_path, mode, *gpu, start)
            }
            (Zkvm::OpenVM, Suite::Isa, None) => run_openvm(binary, elf_path, start),
            (Zkvm::Zisk, Suite::Isa | Suite::Standards, None) => {
                run_zisk(binary, elf_path, vectors, start)
            }
            (Zkvm::Sp1, Suite::Standards, None) => {
                run_io_executor(binary, elf_path, vectors, OutputArea::Exact, start)
            }
            (Zkvm::OpenVM, Suite::Standards, None) => {
                run_io_executor(binary, elf_path, vectors, OutputArea::ZeroPadded, start)
            }
            // `Backend::new` rejects every other combination.
            _ => RunResult::host_error(start, None, format!("runner error: unsupported backend {}", self.name())),
        }
    }
}

/// Zisk proving via `cargo-zisk prove [--verify-proofs]`.
///
/// Lifecycle:
/// 1. Execute: `ziskemu --elf <path> --output <file>` — pass = exit code 0, no
///    "finished with error", and output starts with `PASS`
/// 2. Prove:   `cargo-zisk prove --elf <path> -o <file> [--verify-proof] [--gpu]`
///
/// As of zisk v0.17.0, `-o/--output` is a file path (not a directory) and proofs
/// are aggregated by default (VadcopFinal). In v1.0.0 the Rust emulator became the
/// default (old `--emulator` flag removed), `prove` runs the per-program setup
/// internally, and `--verify-proofs` was renamed `--verify-proof` (in-process verify).
/// If the command fails, we parse stdout to distinguish prove vs verify failure:
/// the presence of "VERIFYING_PROOFS" or "was not verified" means proving
/// succeeded but verification failed.
fn run_zisk_prove(
    ziskemu: &Path,
    cargo_zisk: &Path,
    witness_lib: Option<&Path>,
    elf_path: &Path,
    mode: Mode,
    _gpu: bool,
    start: Instant,
) -> RunResult {
    let inner = || -> anyhow::Result<RunResult> {
        // 1. Execute
        let (passed, exit_code) = run_ziskemu(ziskemu, elf_path, &["--inputs", "/dev/null"]);

        if mode == Mode::Execute || !passed {
            return Ok(RunResult {
                passed,
                exit_code,
                duration: start.elapsed(),
                prove_duration: None,
                proof_written: false,
                prove_status: None,
                verify_status: None,
                termination: Termination::from_success(passed),
                detail: None,
            });
        }

        // Check once whether this cargo-zisk accepts --witness-lib
        let accepts_witness_lib = witness_lib.is_some()
            && Command::new(cargo_zisk)
                .args(["prove", "--help"])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).contains("--witness-lib"))
                .unwrap_or(false);

        let is_gpu = cargo_zisk.to_string_lossy().contains("cuda");
        let verify = mode == Mode::Full;

        // 2. Prove (with --verify-proofs in Full mode)
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
            let (prove_status, verify_status) = if is_verify_failure(&combined) {
                (Some("success".to_string()), Some("failed".to_string()))
            } else {
                (Some("failed".to_string()), None)
            };

            return Ok(RunResult {
                passed: true, // execution passed
                exit_code: Some(0),
                duration: start.elapsed(),
                prove_duration: Some(prove_duration),
                proof_written: false,
                prove_status,
                verify_status,
                termination: Termination::Success,
                detail: None,
            });
        }

        // Success — prove (and verify if requested) all passed
        let proof_written = proof_path.exists();

        Ok(RunResult {
            passed: true,
            exit_code: Some(0),
            duration: start.elapsed(),
            prove_duration: Some(prove_duration),
            proof_written,
            prove_status: Some("success".to_string()),
            verify_status: if verify { Some("success".to_string()) } else { None },
            termination: Termination::Success,
            detail: None,
        })
    };

    match inner() {
        Ok(result) => result,
        Err(e) => {
            eprintln!("error running {}: {e}", elf_path.display());
            RunResult {
                passed: false,
                exit_code: None,
                duration: start.elapsed(),
                prove_duration: None,
                proof_written: false,
                prove_status: None,
                verify_status: None,
                termination: Termination::HostError,
                detail: Some(format!("runner error: {e:#}")),
            }
        }
    }
}

/// SP1 GPU prove+verify via the `sp1-perf` binary.
///
/// Lifecycle:
/// 1. Execute: `sp1-perf-executor --program <elf> --param <stdin> --mode minimal --local`
///    — MinimalExecutor, propagates the guest exit code (0 = pass). SP1's JIT logs
///    "Unimplemented instruction" and continues with exit 0, so that string is also
///    treated as a failure. This step establishes the compliance pass/fail (the
///    prover below ignores the guest exit code).
/// 2. Prove+verify: `sp1-perf --program <elf> --stdin <stdin> --mode cuda`
///    — executes, generates a core proof, and verifies it in one process (exit 0 =
///    prove and verify both succeeded). SP1 always verifies after proving, so prove
///    vs verify failure is distinguished by parsing the output: a `VerificationError`
///    means proving succeeded but verification failed.
///
/// `stdin` is 24 zero bytes (a bincode-serialized empty `SP1Stdin`). `--mode cuda`
/// spawns the host-native `sp1-gpu-server`; see run_zisk_prove for the analogous
/// host-GPU serialization (one prove at a time via jobs=1).
/// Parses the guest exit code from sp1-perf-executor's "exit code: N, cycles: M"
/// line. Upstream sp1-perf-executor always exits 0, so this line is the only
/// place where a failing ACT4 test (`a0 = 1` at halt) shows.
fn sp1_guest_exit_code(output: &str) -> Option<u32> {
    output.lines().find_map(|line| {
        let rest = line.trim().strip_prefix("exit code: ")?;
        rest.split(',').next()?.trim().parse().ok()
    })
}

fn run_sp1_prove(
    executor: &Path,
    sp1_perf: &Path,
    elf_path: &Path,
    mode: Mode,
    gpu: bool,
    start: Instant,
) -> RunResult {
    let inner = || -> anyhow::Result<RunResult> {
        // Empty SP1Stdin (bincode): three zero-length fields = 24 zero bytes.
        let tmp_dir = tempfile::tempdir()?;
        let stdin_path = tmp_dir.path().join("stdin.bin");
        std::fs::write(&stdin_path, [0u8; 24])?;

        // 1. Execute (guest exit code + unimplemented-instruction check).
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

        if mode == Mode::Execute || !passed {
            return Ok(RunResult {
                passed,
                exit_code: exec_output.status.code(),
                duration: start.elapsed(),
                prove_duration: None,
                proof_written: false,
                prove_status: None,
                verify_status: None,
                termination: Termination::from_success(passed),
                detail: None,
            });
        }

        // 2. Prove + verify (one process). GPU-only per project scope: `--mode cuda`
        // spawns the host-native sp1-gpu-server; `cpu` is a slow fallback.
        let prove_mode = if gpu { "cuda" } else { "cpu" };
        let verify = mode == Mode::Full;

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
            let (prove_status, verify_status) = if is_sp1_verify_failure(&combined) {
                (Some("success".to_string()), Some("failed".to_string()))
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
                (Some("failed".to_string()), None)
            };
            return Ok(RunResult {
                passed: true, // execution passed
                exit_code: Some(0),
                duration: start.elapsed(),
                prove_duration: Some(prove_duration),
                proof_written: false,
                prove_status,
                verify_status,
                termination: Termination::Success,
                detail: None,
            });
        }

        // Success — prove (and verify) passed.
        Ok(RunResult {
            passed: true,
            exit_code: Some(0),
            duration: start.elapsed(),
            prove_duration: Some(prove_duration),
            proof_written: true,
            prove_status: Some("success".to_string()),
            verify_status: if verify { Some("success".to_string()) } else { None },
            termination: Termination::Success,
            detail: None,
        })
    };

    match inner() {
        Ok(result) => result,
        Err(e) => {
            eprintln!("error running {}: {e}", elf_path.display());
            RunResult {
                passed: false,
                exit_code: None,
                duration: start.elapsed(),
                prove_duration: None,
                proof_written: false,
                prove_status: None,
                verify_status: None,
                termination: Termination::HostError,
                detail: Some(format!("runner error: {e:#}")),
            }
        }
    }
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
/// reflects the test outcome.
fn run_lambdavm(
    binary: &Path,
    elf_path: &Path,
    mode: Mode,
    start: Instant,
) -> RunResult {
    let inner = || -> anyhow::Result<RunResult> {
        // 1. Execute
        let exec_output = Command::new(binary)
            .arg("execute")
            .arg(elf_path)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()?;
        let passed = exec_output.status.success();

        if mode == Mode::Execute || !passed {
            return Ok(RunResult {
                passed,
                exit_code: exec_output.status.code(),
                duration: start.elapsed(),
                prove_duration: None,
                proof_written: false,
                prove_status: None,
                verify_status: None,
                termination: Termination::from_success(passed),
                detail: None,
            });
        }

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
            return Ok(RunResult {
                passed: true,
                exit_code: Some(0),
                duration: start.elapsed(),
                prove_duration: Some(prove_duration),
                proof_written: false,
                prove_status: Some("failed".to_string()),
                verify_status: None,
                termination: Termination::Success,
                detail: None,
            });
        }

        let proof_written = proof_path.exists();

        // 3. Verify
        let verify_status = if mode == Mode::Full {
            let verify_output = Command::new(binary)
                .args(["verify"])
                .arg(&proof_path)
                .arg(elf_path)
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .output()?;

            if verify_output.status.success() {
                Some("success".to_string())
            } else {
                let verify_stderr = String::from_utf8_lossy(&verify_output.stderr);
                eprintln!(
                    "lambdavm verify failed for {}: {}",
                    elf_path.display(),
                    verify_stderr.lines().last().unwrap_or("(no output)"),
                );
                Some("failed".to_string())
            }
        } else {
            None
        };

        Ok(RunResult {
            passed: true,
            exit_code: Some(0),
            duration: start.elapsed(),
            prove_duration: Some(prove_duration),
            proof_written,
            prove_status: Some("success".to_string()),
            verify_status,
            termination: Termination::Success,
            detail: None,
        })
    };

    match inner() {
        Ok(result) => result,
        Err(e) => {
            eprintln!("error running {}: {e}", elf_path.display());
            RunResult {
                passed: false,
                exit_code: None,
                duration: start.elapsed(),
                prove_duration: None,
                proof_written: false,
                prove_status: None,
                verify_status: None,
                termination: Termination::HostError,
                detail: Some(format!("runner error: {e:#}")),
            }
        }
    }
}

/// OpenVM: invoke `<binary> execute <elf_path>`.
///
/// The standalone runner exits 0 on a clean guest halt(0) and non-zero on any guest
/// failure (the SDK surfaces a non-zero guest exit code as an error).
fn run_openvm(binary: &Path, elf_path: &Path, start: Instant) -> RunResult {
    let status = Command::new(binary)
        .arg("execute")
        .arg(elf_path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    match status {
        Ok(s) => RunResult::executed(start, s.code(), Termination::from_success(s.success()), None),
        Err(e) => RunResult::host_error(start, None, format!("runner error: failed to run {}: {e}", binary.display())),
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
/// mirroring the zisk-prove backend's GPU hygiene.
fn run_openvm_prove(
    binary: &Path,
    elf_path: &Path,
    mode: Mode,
    gpu: bool,
    start: Instant,
) -> RunResult {
    let inner = || -> anyhow::Result<RunResult> {
        // 1. Execute
        let exec_output = Command::new(binary)
            .arg("execute")
            .arg(elf_path)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()?;
        let passed = exec_output.status.success();

        if mode == Mode::Execute || !passed {
            return Ok(RunResult {
                passed,
                exit_code: exec_output.status.code(),
                duration: start.elapsed(),
                prove_duration: None,
                proof_written: false,
                prove_status: None,
                verify_status: None,
                termination: Termination::from_success(passed),
                detail: None,
            });
        }

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
            return Ok(RunResult {
                passed: true,
                exit_code: Some(0),
                duration: start.elapsed(),
                prove_duration: Some(prove_duration),
                proof_written: false,
                prove_status: Some("failed".to_string()),
                verify_status: None,
                termination: Termination::Success,
                detail: None,
            });
        }

        let proof_written = proof_path.exists();

        // 3. Verify
        let verify_status = if mode == Mode::Full {
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
                Some("success".to_string())
            } else {
                let verify_stderr = String::from_utf8_lossy(&verify_output.stderr);
                eprintln!(
                    "openvm verify failed for {}: {}",
                    elf_path.display(),
                    verify_stderr.lines().last().unwrap_or("(no output)"),
                );
                Some("failed".to_string())
            }
        } else {
            None
        };

        Ok(RunResult {
            passed: true,
            exit_code: Some(0),
            duration: start.elapsed(),
            prove_duration: Some(prove_duration),
            proof_written,
            prove_status: Some("success".to_string()),
            verify_status,
            termination: Termination::Success,
            detail: None,
        })
    };

    match inner() {
        Ok(result) => result,
        Err(e) => {
            eprintln!("error running {}: {e}", elf_path.display());
            RunResult {
                passed: false,
                exit_code: None,
                duration: start.elapsed(),
                prove_duration: None,
                proof_written: false,
                prove_status: None,
                verify_status: None,
                termination: Termination::HostError,
                detail: Some(format!("runner error: {e:#}")),
            }
        }
    }
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

/// Zisk: invoke `<binary> -e <elf_path> -o <file>`, with `-i` (the framed input)
/// when the test has an input vector.
///
/// Termination:
/// - ZisK reports no error code: ZisK >= 1.2 ignores `a0` at the exit ecall.
///   A non-zero `ziskemu` exit or "finished with error" on stderr (it can exit 0
///   after an emulation error) means that ZisK rejected the execution, so the
///   guest terminated abnormally without a code.
/// - Without an expected-output vector (ACT4 verdict), the ZisK ACT4 halt
///   macros write `PASS` or `FAIL` to public output 0
///   (zkvms/zisk/isa-configs/*/rvmodel_macros.h). `FAIL` is an abnormal
///   termination. Otherwise the output must start with `PASS`.
/// - With an expected-output vector: ZisK's public output is a fixed area of 64
///   u32 words with zero padding, so it must equal the expected bytes followed
///   by zero bytes.
/// - A spawn failure, a missing output file or a death by signal is a host error.
fn run_zisk(binary: &Path, elf_path: &Path, vectors: &IoVectors, start: Instant) -> RunResult {
    let inner = || -> anyhow::Result<RunResult> {
        let tmp = tempfile::tempdir().context("failed to create temp dir")?;
        let input_path = tmp.path().join("input.bin");
        let output_path = tmp.path().join("output.bin");

        let mut cmd = Command::new(binary);
        cmd.arg("-e").arg(elf_path);
        if let Some(input) = &vectors.input {
            std::fs::write(&input_path, io::zisk_frame_input(input))?;
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
        let reason = io::emulator_error_reason(&stderr);
        if exit_code.is_none() {
            let detail = format!("emulator killed by a signal: {reason}");
            return Ok(RunResult::host_error(start, exit_code, detail));
        }
        if !output.status.success() || stderr.contains("finished with error") {
            let detail = format!("emulator error (exit {}): {reason}", exit_text(exit_code));
            let failure = Termination::Failure { code: None };
            return Ok(RunResult::executed(start, exit_code, failure, Some(detail)));
        }

        let Ok(actual) = std::fs::read(&output_path) else {
            return Ok(RunResult::host_error(start, exit_code, "emulator wrote no output file".to_owned()));
        };
        let (termination, detail) = match &vectors.expected {
            None if actual.starts_with(b"FAIL") => {
                (Termination::Failure { code: None }, Some("public output has the FAIL marker".to_owned()))
            }
            None => (
                Termination::Success,
                (!actual.starts_with(b"PASS")).then(|| "public output does not start with the PASS marker".to_owned()),
            ),
            Some(expected) => (
                Termination::Success,
                (!io::matches_zero_padded(&actual, expected)).then(|| io::describe_mismatch(&actual, expected)),
            ),
        };
        Ok(RunResult::executed(start, exit_code, termination, detail))
    };
    inner().unwrap_or_else(|e| RunResult::host_error(start, None, format!("runner error: {e:#}")))
}

/// Runs `ziskemu` on `elf_path` and returns the ACT4 verdict and the exit code.
///
/// ZisK >= 1.2 ignores `a0` at the exit ecall, so a failing test exits like a
/// passing one. The ZisK ACT4 halt macros therefore also write `PASS` or `FAIL`
/// to public output 0 (zkvms/zisk/isa-configs/*/rvmodel_macros.h). A test passes only
/// if ziskemu succeeds, prints no "finished with error" (it can exit 0 after an
/// emulation error), and its output starts with `PASS`.
fn run_ziskemu(ziskemu: &Path, elf_path: &Path, extra_args: &[&str]) -> (bool, Option<i32>) {
    let Ok(tmp_dir) = tempfile::tempdir() else {
        return (false, None);
    };
    let output_path = tmp_dir.path().join("output.bin");
    let output = Command::new(ziskemu)
        .arg("--elf")
        .arg(elf_path)
        .args(extra_args)
        .arg("--output")
        .arg(&output_path)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output();

    match output {
        Ok(o) => {
            let code = o.status.code();
            let stderr = String::from_utf8_lossy(&o.stderr);
            let verdict_pass = std::fs::read(&output_path)
                .is_ok_and(|public_output| public_output.starts_with(b"PASS"));
            let passed =
                o.status.success() && !stderr.contains("finished with error") && verdict_pass;
            (passed, code)
        }
        Err(_) => (false, None),
    }
}

/// How a standards executor's public output compares with the expected bytes.
#[derive(Clone, Copy)]
enum OutputArea {
    /// A variable-length stream (SP1): the output must equal the expected bytes.
    Exact,
    /// A fixed area with zero padding (OpenVM with ere's VM config: 256 bytes).
    ZeroPadded,
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
fn run_io_executor(
    executor: &Path,
    elf_path: &Path,
    vectors: &IoVectors,
    area: OutputArea,
    start: Instant,
) -> RunResult {
    let inner = || -> anyhow::Result<RunResult> {
        let tmp = tempfile::tempdir().context("failed to create temp dir")?;
        let input_path = tmp.path().join("input.bin");
        let output_path = tmp.path().join("public-values.bin");
        let code_path = tmp.path().join("exit-code.txt");
        std::fs::write(&input_path, vectors.input.as_deref().unwrap_or_default())?;

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
        let reason = io::emulator_error_reason(&String::from_utf8_lossy(&output.stderr));
        match exit_code {
            Some(0) => {}
            Some(1) => {
                let code = match std::fs::read_to_string(&code_path) {
                    Ok(text) => match parse_error_code(&text) {
                        Some(code) => Some(code),
                        None => {
                            let detail = format!("executor wrote an invalid exit code {:?}", text.trim());
                            return Ok(RunResult::host_error(start, exit_code, detail));
                        }
                    },
                    Err(_) => None,
                };
                let code_text = code.map_or_else(|| "no error code".to_owned(), |c| format!("error code {c}"));
                let detail = format!("guest terminated abnormally ({code_text}): {reason}");
                return Ok(RunResult::executed(start, exit_code, Termination::Failure { code }, Some(detail)));
            }
            _ => {
                let detail = format!("executor error (exit {}): {reason}", exit_text(exit_code));
                return Ok(RunResult::host_error(start, exit_code, detail));
            }
        }

        // The pass halt is exit code 0, which a return from main also gives, so
        // a test without an expected output must write the PASS verdict
        // (tests/eth-act-standards/include/checks.h).
        let expected = vectors.expected.as_deref().unwrap_or(io::PASS_OUTPUT);
        let Ok(actual) = std::fs::read(&output_path) else {
            return Ok(RunResult::host_error(start, exit_code, "executor wrote no public values".to_owned()));
        };
        let detail = match area {
            OutputArea::Exact => (actual != expected).then(|| io::describe_exact_mismatch(&actual, expected)),
            OutputArea::ZeroPadded => {
                (!io::matches_zero_padded(&actual, expected)).then(|| io::describe_mismatch(&actual, expected))
            }
        };
        Ok(RunResult::executed(start, exit_code, Termination::Success, detail))
    };
    inner().unwrap_or_else(|e| RunResult::host_error(start, None, format!("runner error: {e:#}")))
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
    use std::path::PathBuf;

    /// Every `--zkvm` name with its suite and whether it proves.
    const NAMES: [(&str, Suite, bool); 9] = [
        ("lambdavm", Suite::Isa, false),
        ("openvm", Suite::Isa, false),
        ("openvm-prove", Suite::Isa, true),
        ("sp1-prove", Suite::Isa, true),
        ("zisk", Suite::Isa, false),
        ("zisk-prove", Suite::Isa, true),
        ("zisk-standards", Suite::Standards, false),
        ("sp1-standards", Suite::Standards, false),
        ("openvm-standards", Suite::Standards, false),
    ];

    fn prover(zkvm: Zkvm) -> Prover {
        let tools = match zkvm {
            Zkvm::Sp1 => ProverTools::Sp1 { sp1_perf: PathBuf::from("sp1-perf") },
            Zkvm::Zisk => ProverTools::Zisk { cargo_zisk: PathBuf::from("cargo-zisk"), witness_lib: None },
            Zkvm::OpenVM | Zkvm::LambdaVM => ProverTools::OpenVM,
        };
        Prover { gpu: false, tools }
    }

    #[test]
    fn builds_a_backend_from_each_name() {
        for (name, suite, prove) in NAMES {
            let parsed = parse_name(name).unwrap_or_else(|| panic!("{name} does not parse"));
            assert_eq!((parsed.1, parsed.2), (suite, prove), "{name}");
            let zkvm = parsed.0;
            let backend = Backend::new(zkvm, suite, PathBuf::from("bin"), prove.then(|| prover(zkvm))).unwrap();
            assert_eq!(backend.name(), name);
            assert_eq!(backend.is_standards(), suite == Suite::Standards, "{name}");
            assert_eq!(backend.prove.is_some(), prove, "{name}");
            assert_eq!(backend.binary, PathBuf::from("bin"));
        }
    }

    #[test]
    fn only_zisk_isa_execute_and_standards_backends_support_io() {
        for (name, suite, prove) in NAMES {
            let (zkvm, ..) = parse_name(name).unwrap();
            let backend = Backend::new(zkvm, suite, PathBuf::from("bin"), prove.then(|| prover(zkvm))).unwrap();
            let expected = matches!(name, "zisk" | "zisk-standards" | "sp1-standards" | "openvm-standards");
            assert_eq!(backend.supports_io(), expected, "{name}");
        }
    }

    #[test]
    fn rejects_unknown_names_and_unsupported_combinations() {
        for name in ["sp1", "lambdavm-prove", "lambdavm-standards", "zisk-prove-standards", "risc0", ""] {
            assert_eq!(parse_name(name), None, "{name}");
        }
    }

    #[test]
    fn rejects_unsupported_backends() {
        let bin = || PathBuf::from("bin");
        // LambdaVM has no standards backend and no prover.
        assert!(Backend::new(Zkvm::LambdaVM, Suite::Standards, bin(), None).is_err());
        assert!(Backend::new(Zkvm::LambdaVM, Suite::Isa, bin(), Some(prover(Zkvm::OpenVM))).is_err());
        // The standards suite is execute only.
        assert!(Backend::new(Zkvm::Zisk, Suite::Standards, bin(), Some(prover(Zkvm::Zisk))).is_err());
        // SP1 runs the ISA tests only through its prove backend.
        assert!(Backend::new(Zkvm::Sp1, Suite::Isa, bin(), None).is_err());
        // The prover tools must belong to the zkVM.
        assert!(Backend::new(Zkvm::Zisk, Suite::Isa, bin(), Some(prover(Zkvm::Sp1))).is_err());
        assert!(Backend::new(Zkvm::OpenVM, Suite::Isa, bin(), Some(prover(Zkvm::Zisk))).is_err());
    }
    use std::sync::Mutex;

    use super::*;
    use crate::io::Outcome;

    /// Serializes the tests that write and spawn fake executors: a script
    /// that another thread's fork holds open for writing fails with ETXTBSY.
    static SPAWN: Mutex<()> = Mutex::new(());

    fn vectors(expected: Option<&[u8]>) -> IoVectors {
        IoVectors { input: Some(Vec::new()), expected: expected.map(<[u8]>::to_vec), outcome: Outcome::Pass }
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
        run_io_executor(&executor, &elf, &vectors(expected), OutputArea::Exact, Instant::now())
    }

    /// Run a fake `ziskemu` (the last argument is the output file).
    fn ziskemu(body: &str, expected: Option<&[u8]>) -> RunResult {
        let _guard = SPAWN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let emulator = fake(dir.path(), "ziskemu", &format!("for out; do :; done\n{body}"));
        let elf = dir.path().join("t.elf");
        run_zisk(&emulator, &elf, &vectors(expected), Instant::now())
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
        let r = run_io_executor(&missing, &missing, &vectors(None), OutputArea::Exact, Instant::now());
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
        let r = ziskemu("kill -9 $$", None);
        assert_eq!(r.termination, Termination::HostError);
        assert!(r.detail.unwrap().starts_with("emulator killed by a signal"));

        let r = ziskemu("exit 0", None);
        assert_eq!(r.termination, Termination::HostError);
        assert_eq!(r.detail.as_deref(), Some("emulator wrote no output file"));

        let _guard = SPAWN.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("missing");
        let r = run_zisk(&missing, &missing, &vectors(None), Instant::now());
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
            let backend = Backend::new(Zkvm::Sp1, Suite::Standards, executor, None).unwrap();
            crate::runner::run_one(&backend, &elf, Mode::Execute)
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
}
