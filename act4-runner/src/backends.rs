use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::elf_utils;

/// Supported ZK-VM backends for running ACT4 compliance tests.
pub enum Backend {
    Airbender { binary: PathBuf },
    AirbenderProve { binary: PathBuf, gpu: bool, proof_dir: PathBuf },
    Jolt { binary: PathBuf },
    JoltProve { jolt_emu: PathBuf, jolt_prover: PathBuf },
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
            Backend::JoltProve { jolt_emu, jolt_prover } => {
                run_jolt_prove(jolt_emu, jolt_prover, elf_path, mode, start)
            }
            Backend::ZiskProve { ziskemu, cargo_zisk, witness_lib, gpu } => {
                run_zisk_prove(ziskemu, cargo_zisk, witness_lib.as_deref(), elf_path, mode, *gpu, start)
            }
            _ => {
                let (passed, exit_code) = match self {
                    Backend::Airbender { binary } => run_airbender(binary, elf_path),
                    Backend::Jolt { binary } => run_jolt(binary, elf_path),
                    Backend::OpenVM { binary } => run_openvm(binary, elf_path),
                    Backend::Zisk { binary } => run_zisk(binary, elf_path),
                    Backend::AirbenderProve { .. }
                    | Backend::JoltProve { .. }
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

/// Zisk proving via `cargo-zisk prove` (single command, no server needed).
///
/// Lifecycle:
/// 1. Execute: `ziskemu --elf <path>` — exit code 0 = pass
/// 2. Prove:   `cargo-zisk prove --elf <path> --emulator --aggregation --verify_proofs`
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

        // 2. Prove (and optionally verify) via single cargo-zisk prove invocation
        let tmp_dir = tempfile::tempdir()?;
        let prove_start = Instant::now();

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
        cmd.args(["-o"]).arg(tmp_dir.path());

        if mode == Mode::Full {
            cmd.arg("--verify-proofs");
        }

        // Note: --aggregation requires per-ELF rom-setup (assembly JIT compilation)
        // which needs the full build tree. Without it, basic proofs are still generated
        // and the exit code indicates success/failure.

        let is_gpu = cargo_zisk.to_string_lossy().contains("cuda");

        let prove_output = cmd.output()?;
        let prove_duration = prove_start.elapsed();

        // Clean up after every prove (success or failure). cargo-zisk uses
        // OpenMP and MPI which leave shared memory files (__KMP_REGISTERED_LIB_*,
        // sem.mp-*) from child processes. If these accumulate from dead PIDs,
        // subsequent proves can fail or hang.
        cleanup_stale_shm();

        // GPU-specific cleanup: kill zombie processes and wait for GPU memory
        // to be released. This runs after every GPU prove, not just failures —
        // a "successful" prove can still leave child processes behind.
        if is_gpu {
            if !prove_output.status.success() {
                kill_cargo_zisk_processes();
            }
            wait_for_gpu_free(Duration::from_secs(30));
        }

        // Retry once on failure — cascading failures from stale GPU/shm state
        // are common, and the cleanup above usually fixes them.
        if !prove_output.status.success() {
            let stderr = String::from_utf8_lossy(&prove_output.stderr);
            eprintln!(
                "cargo-zisk prove failed for {} (retrying): {}",
                elf_path.display(),
                stderr.lines().last().unwrap_or("(no output)"),
            );

            let mut retry_cmd = Command::new(cargo_zisk);
            unsafe {
                retry_cmd.pre_exec(|| {
                    let zero = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
                    libc::setrlimit(libc::RLIMIT_CORE, &zero);
                    Ok(())
                });
            }
            retry_cmd.process_group(0);
            retry_cmd.args(["prove", "--elf"]).arg(elf_path);
            if let Some(wl) = witness_lib {
                retry_cmd.arg("--witness-lib").arg(wl);
            }
            retry_cmd.arg("--emulator");
            retry_cmd.args(["-o"]).arg(tmp_dir.path());
            if mode == Mode::Full {
                retry_cmd.arg("--verify-proofs");
            }

            let retry_start = Instant::now();
            let retry_output = retry_cmd.output()?;
            let retry_duration = retry_start.elapsed();

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
                return Ok(RunResult {
                    passed: true, // execution passed, proving failed
                    exit_code: Some(0),
                    duration: start.elapsed(),
                    prove_duration: Some(prove_duration + retry_duration),
                    proof_written: false,
                    prove_status: Some("failed".to_string()),
                    verify_status: None,
                });
            }
            // Retry succeeded — fall through to success handling
            eprintln!("cargo-zisk prove retry succeeded for {}", elf_path.display());
        }

        // Check if proof file was written
        let proof_path = tmp_dir.path().join("vadcop_final_proof.bin");
        let proof_written = proof_path.exists();

        let verify_status = if mode == Mode::Full {
            // --verify_proofs flag handles verification during proving;
            // if the command succeeded, verification passed.
            Some("success".to_string())
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

/// Jolt: invoke `<binary> <elf_path>`.
///
/// jolt-emu always exits 0 regardless of test pass/fail — it logs
/// "Test Failed" to stderr but never calls process::exit. We parse
/// stderr to determine the actual result.
fn run_jolt(binary: &Path, elf_path: &Path) -> (bool, Option<i32>) {
    let output = Command::new(binary)
        .arg(elf_path)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output();

    match output {
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            let failed = stderr.contains("Test Failed");
            let passed = o.status.success() && !failed;
            (passed, o.status.code())
        }
        Err(_) => (false, None),
    }
}

/// Jolt proving via `jolt-prover prove` CLI.
///
/// Lifecycle:
/// 1. Execute: `jolt-emu <elf>` — parse stderr for pass/fail
/// 2. Prove:   `jolt-prover prove <elf> -o <tmpdir> [--verify]`
fn run_jolt_prove(
    jolt_emu: &Path,
    jolt_prover: &Path,
    elf_path: &Path,
    mode: Mode,
    start: Instant,
) -> RunResult {
    let inner = || -> anyhow::Result<RunResult> {
        // 1. Execute
        let exec_output = Command::new(jolt_emu)
            .arg(elf_path)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()?;
        let stderr = String::from_utf8_lossy(&exec_output.stderr);
        let failed = stderr.contains("Test Failed");
        let passed = exec_output.status.success() && !failed;

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

        // 2. Prove (and optionally verify)
        let tmp_dir = tempfile::tempdir()?;
        let prove_start = Instant::now();

        let mut cmd = Command::new(jolt_prover);
        cmd.args(["prove"]).arg(elf_path);
        cmd.arg("-o").arg(tmp_dir.path());
        if mode == Mode::Full {
            cmd.arg("--verify");
        }

        let prove_output = cmd.output()?;
        let prove_duration = prove_start.elapsed();

        if !prove_output.status.success() {
            let prove_stderr = String::from_utf8_lossy(&prove_output.stderr);
            eprintln!(
                "jolt-prover failed for {}: {}",
                elf_path.display(),
                prove_stderr.lines().last().unwrap_or("(no output)"),
            );
            return Ok(RunResult {
                passed: true, // execution passed, proving failed
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

        let verify_status = if mode == Mode::Full {
            // --verify flag handles verification during proving;
            // if the command succeeded, verification passed.
            Some("success".to_string())
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
    let status = Command::new(binary)
        .arg("-e")
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
