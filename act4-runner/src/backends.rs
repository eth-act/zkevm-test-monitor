use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::elf_utils;

/// Supported ZK-VM backends for running ACT4 compliance tests.
pub enum Backend {
    Airbender { binary: PathBuf },
    AirbenderProve { binary: PathBuf, gpu: bool, proof_dir: PathBuf },
    Jolt { jolt_prover: PathBuf },
    OpenVM { binary: PathBuf },
    Zisk { binary: PathBuf },
    ZiskProve {
        ziskemu: PathBuf,
        cargo_zisk: PathBuf,
        witness_lib: Option<PathBuf>,
        gpu: bool,
    },
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
}

impl Backend {
    /// Execute an ELF test through the backend and return the result.
    ///
    /// For most backends, `mode` is ignored (execute-only). The `JoltProve`
    /// and `ZiskProve` backends use `mode` to control whether to prove
    /// and/or verify.
    pub fn run_elf(&self, elf_path: &Path, mode: Mode) -> RunResult {
        let start = Instant::now();

        match self {
            Backend::AirbenderProve { binary, gpu, proof_dir } => {
                run_airbender_prove(binary, elf_path, *gpu, proof_dir)
            }
            Backend::Jolt { jolt_prover } => {
                run_jolt(jolt_prover, elf_path, mode, start)
            }
            Backend::ZiskProve { ziskemu, cargo_zisk, witness_lib, gpu } => {
                run_zisk_prove(ziskemu, cargo_zisk, witness_lib.as_deref(), elf_path, mode, *gpu, start)
            }
            _ => {
                let (passed, exit_code) = match self {
                    Backend::Airbender { binary } => run_airbender(binary, elf_path),
                    Backend::OpenVM { binary } => run_openvm(binary, elf_path),
                    Backend::Zisk { binary } => run_zisk(binary, elf_path),
                    Backend::AirbenderProve { .. }
                    | Backend::Jolt { .. }
                    | Backend::ZiskProve { .. } => unreachable!(),
                };

                RunResult {
                    passed,
                    exit_code,
                    duration: start.elapsed(),
                    prove_duration: None,
                    proof_written: false,
                    prove_status: None,
                    verify_status: None,
                }
            }
        }
    }
}

/// Zisk proving via `cargo-zisk prove [--verify-proofs]`.
///
/// Lifecycle:
/// 1. Execute: `ziskemu --elf <path>` — exit code 0 = pass
/// 2. Prove:   `cargo-zisk prove --elf <path> --emulator [-o <dir>] [--verify-proofs]`
///
/// In Full mode, `--verify-proofs` triggers in-memory verification during
/// the prove step (no separate proof file is produced without `--aggregation`).
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
        // Note: ziskemu may exit 0 even when the emulator reports an error
        // (e.g. "Emu::par_run() finished with error"), so also check stderr.
        let exec_output = Command::new(ziskemu)
            .arg("--elf")
            .arg(elf_path)
            .arg("--inputs")
            .arg("/dev/null")
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()?;
        let stderr = String::from_utf8_lossy(&exec_output.stderr);
        let passed = exec_output.status.success()
            && !stderr.contains("finished with error");

        if mode == Mode::Execute || !passed {
            return Ok(RunResult {
                passed,
                exit_code: exec_output.status.code(),
                duration: start.elapsed(),
                prove_duration: None,
                proof_written: false,
                prove_status: None,
                verify_status: None,
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

        let prove_output = {
            let mut cmd = zisk_prove_cmd(cargo_zisk, elf_path, tmp_dir.path(),
                                          witness_lib.filter(|_| accepts_witness_lib), verify);
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
                eprintln!(
                    "cargo-zisk prove failed for {} (retrying): {}",
                    elf_path.display(),
                    stderr.lines().last().unwrap_or("(no output)"),
                );

                let retry_start = Instant::now();
                let retry_output = {
                    let mut cmd = zisk_prove_cmd(cargo_zisk, elf_path, tmp_dir.path(),
                                                  witness_lib.filter(|_| accepts_witness_lib), verify);
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
                    eprintln!(
                        "cargo-zisk prove failed for {} (retry also failed): {}",
                        elf_path.display(),
                        retry_stderr.lines().last().unwrap_or("(no output)"),
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
            });
        }

        // Success — prove (and verify if requested) all passed
        let proof_path = tmp_dir.path().join("vadcop_final_proof.bin");
        let proof_written = proof_path.exists();

        Ok(RunResult {
            passed: true,
            exit_code: Some(0),
            duration: start.elapsed(),
            prove_duration: Some(prove_duration),
            proof_written,
            prove_status: Some("success".to_string()),
            verify_status: if verify { Some("success".to_string()) } else { None },
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
            }
        }
    }
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
fn zisk_prove_cmd(
    cargo_zisk: &Path,
    elf_path: &Path,
    out_dir: &Path,
    witness_lib: Option<&Path>,
    verify: bool,
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
    cmd.arg("--emulator");
    cmd.args(["-o"]).arg(out_dir);
    if verify {
        cmd.arg("--verify-proofs");
    }
    // Capture both stdout and stderr for output parsing
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    cmd
}

/// Airbender: convert ELF to flat binary, invoke via `run --bin`, and parse
/// the `Result:` line from stdout. Register a0 (first value) = 0 means pass.
fn run_airbender(binary: &Path, elf_path: &Path) -> (bool, Option<i32>) {
    let inner = || -> anyhow::Result<(bool, Option<i32>)> {
        let bin_path = elf_path.with_extension("bin");
        elf_utils::elf_to_flat_binary(elf_path, &bin_path)?;

        let output = Command::new(binary)
            .args(["run", "--bin"])
            .arg(&bin_path)
            .stderr(Stdio::null())
            .output();

        let _ = std::fs::remove_file(&bin_path);
        let output = output?;

        if !output.status.success() {
            return Ok((false, output.status.code()));
        }

        // Parse "Result: v0, v1, ..." from stdout — a0 (v0) = 0 means pass.
        let stdout = String::from_utf8_lossy(&output.stdout);
        let a0 = stdout.lines().find_map(|line| {
            let rest = line.split_once("Result:")?.1;
            rest.split(',').next()?.trim().parse::<u32>().ok()
        });

        match a0 {
            Some(0) => Ok((true, Some(0))),
            Some(v) => Ok((false, Some(v as i32))),
            None => Ok((false, None)),
        }
    };

    match inner() {
        Ok((passed, code)) => (passed, code),
        Err(_) => (false, None),
    }
}

/// Jolt: uses `jolt-prover` for both execution testing and proving.
///
/// Lifecycle:
/// 1. Execute: `jolt-prover trace <elf>` — exit 0 = pass, exit 1 = panic/fail
/// 2. Prove:   `jolt-prover prove <elf> [--verify]`
///
/// The tracer uses the same code path as the prover (tracer::trace via
/// CheckpointingTracer), not the jolt-emu run_test path.
fn run_jolt(
    jolt_prover: &Path,
    elf_path: &Path,
    mode: Mode,
    start: Instant,
) -> RunResult {
    let inner = || -> anyhow::Result<RunResult> {
        // 1. Execute via tracer
        let exec_output = Command::new(jolt_prover)
            .args(["trace"])
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
            });
        }

        // 2. Prove
        let tmp_dir = tempfile::tempdir()?;
        let prove_start = Instant::now();

        let prove_output = Command::new(jolt_prover)
            .args(["prove"])
            .arg(elf_path)
            .arg("-o").arg(tmp_dir.path())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()?;
        let prove_duration = prove_start.elapsed();

        if !prove_output.status.success() {
            let prove_stderr = String::from_utf8_lossy(&prove_output.stderr);
            eprintln!(
                "jolt-prover prove failed for {}: {}",
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
            });
        }

        let proof_path = tmp_dir.path().join("proof.bin");
        let proof_written = proof_path.exists();

        // 3. Verify (separate step so we can distinguish prove vs verify failure)
        let verify_status = if mode == Mode::Full {
            let verify_output = Command::new(jolt_prover)
                .args(["prove"])
                .arg(elf_path)
                .arg("--verify")
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .output()?;

            if verify_output.status.success() {
                Some("success".to_string())
            } else {
                let verify_stderr = String::from_utf8_lossy(&verify_output.stderr);
                eprintln!(
                    "jolt-prover verify failed for {}: {}",
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
            }
        }
    }
}

/// OpenVM: invoke `<binary> <elf_path>`.
fn run_openvm(binary: &Path, elf_path: &Path) -> (bool, Option<i32>) {
    let status = Command::new(binary)
        .arg(elf_path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    match status {
        Ok(s) => {
            let code = s.code();
            (s.success(), code)
        }
        Err(_) => (false, None),
    }
}

/// Zisk: invoke `<binary> -e <elf_path>`.
fn run_zisk(binary: &Path, elf_path: &Path) -> (bool, Option<i32>) {
    // Capture stderr: ziskemu exits 0 even when emulation fails, but prints
    // "finished with error" to stderr. Check both exit code and stderr.
    let output = Command::new(binary)
        .arg("-e")
        .arg(elf_path)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output();

    match output {
        Ok(o) => {
            let code = o.status.code();
            let stderr = String::from_utf8_lossy(&o.stderr);
            let passed = o.status.success() && !stderr.contains("finished with error");
            (passed, code)
        }
        Err(_) => (false, None),
    }
}

// --- Proof JSON deserialization ---

#[derive(serde::Deserialize)]
struct ProofRegisterValue {
    value: u32,
}

#[derive(serde::Deserialize)]
struct ProgramProof {
    register_final_values: Vec<ProofRegisterValue>,
}

/// AirbenderProve: convert ELF to flat binary, invoke `airbender-cli prove`,
/// read the proof JSON, and extract pass/fail from register a0 (index 10).
fn run_airbender_prove(binary: &Path, elf_path: &Path, gpu: bool, proof_dir: &Path) -> RunResult {
    let start = Instant::now();

    let inner = || -> anyhow::Result<RunResult> {
        // Create per-test output directory: proof_dir/<test_name>/
        let test_name = elf_path
            .file_stem()
            .and_then(|n| n.to_str())
            .unwrap_or("unknown");
        let out_dir = proof_dir.join(test_name);
        std::fs::create_dir_all(&out_dir)?;

        // Write ROM-only .bin (code + read-only data, excluding writable .exit_data/.bss above 2MB).
        let bin_path = out_dir.join(format!("{test_name}.bin"));
        elf_utils::elf_to_rom_binary(elf_path, &bin_path)?;

        let prove_start = Instant::now();
        let mut cmd = Command::new(binary);
        cmd.args([
            "prove",
            "--bin",
        ]);
        cmd.arg(&bin_path);
        cmd.args([
            "--output-dir",
        ]);
        cmd.arg(&out_dir);
        cmd.args([
            "--until", "final-recursion",
            "--cycles", "18446744073709551615",
        ]);
        if gpu {
            cmd.arg("--gpu");
        }

        let output = cmd.output()?;
        let prove_duration = prove_start.elapsed();

        let _ = std::fs::remove_file(&bin_path);

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            eprintln!("prove failed for {test_name}: {}", stderr.trim());
            return Ok(RunResult {
                passed: false,
                exit_code: output.status.code(),
                duration: start.elapsed(),
                prove_duration: Some(prove_duration),
                proof_written: false,
                prove_status: Some("failed".to_string()),
                verify_status: None,
            });
        }

        // Read proof JSON and extract a0 (register index 10)
        let proof_path = out_dir.join("recursion_program_proof.json");
        let proof_json = std::fs::read_to_string(&proof_path)?;
        let proof: ProgramProof = serde_json::from_str(&proof_json)?;

        let a0 = proof
            .register_final_values
            .get(10)
            .map(|r| r.value);

        let (passed, exit_code) = match a0 {
            Some(0) => (true, Some(0)),
            Some(v) => (false, Some(v as i32)),
            None => (false, None),
        };

        Ok(RunResult {
            passed,
            exit_code,
            duration: start.elapsed(),
            prove_duration: Some(prove_duration),
            proof_written: true,
            prove_status: Some("success".to_string()),
            verify_status: None,
        })
    };

    match inner() {
        Ok(result) => result,
        Err(e) => {
            let test_name = elf_path
                .file_stem()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown");
            eprintln!("error proving {test_name}: {e}");
            RunResult {
                passed: false,
                exit_code: None,
                duration: start.elapsed(),
                prove_duration: None,
                proof_written: false,
                prove_status: None,
                verify_status: None,
            }
        }
    }
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
