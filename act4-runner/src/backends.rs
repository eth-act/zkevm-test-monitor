use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::elf_utils;

/// Supported ZK-VM backends for running ACT4 compliance tests.
pub enum Backend {
    Airbender { binary: PathBuf },
    AirbenderProve { binary: PathBuf, gpu: bool, proof_dir: PathBuf },
    OpenVM { binary: PathBuf },
    Zisk { binary: PathBuf },
    ZiskEre,
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
    /// For most backends, `mode` is ignored (execute-only). The `ZiskEre`
    /// backend uses `mode` to control whether to prove and/or verify.
    pub fn run_elf(&self, elf_path: &Path, mode: Mode) -> RunResult {
        let start = Instant::now();

        match self {
            Backend::AirbenderProve { binary, gpu, proof_dir } => {
                run_airbender_prove(binary, elf_path, *gpu, proof_dir)
            }
            Backend::ZiskEre => {
                run_zisk_ere(elf_path, mode, start)
            }
            _ => {
                let (passed, exit_code) = match self {
                    Backend::Airbender { binary } => run_airbender(binary, elf_path),
                    Backend::OpenVM { binary } => run_openvm(binary, elf_path),
                    Backend::Zisk { binary } => run_zisk(binary, elf_path),
                    Backend::AirbenderProve { .. } | Backend::ZiskEre => unreachable!(),
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

/// Zisk via ere: use ere-zisk's execute/prove/verify API.
///
/// - Execute: `ZiskProgram::from_elf()` → `EreZisk::new()` → `zkvm.execute()`.
///   ere returns Err on non-zero exit, which we interpret as test failure.
/// - Prove: `zkvm.prove()` → Ok means proof generated, Err means prover failed.
/// - Verify: `zkvm.verify(&proof)` → Ok means verified.
fn run_zisk_ere(elf_path: &Path, mode: Mode, start: Instant) -> RunResult {
    use ere_zisk::program::ZiskProgram;
    use ere_zisk::EreZisk;
    use ere_zkvm_interface::zkvm::{Input, ProofKind, ProverResource, zkVM};

    let inner = || -> anyhow::Result<RunResult> {
        let elf_bytes = std::fs::read(elf_path)?;
        let program = ZiskProgram::from_elf(elf_bytes);
        let zkvm = EreZisk::new(program, ProverResource::Cpu)?;

        // Execute
        let exec_result = zkvm.execute(&Input::new());
        let passed = exec_result.is_ok();

        if mode == Mode::Execute || !passed {
            return Ok(RunResult {
                passed,
                exit_code: if passed { Some(0) } else { Some(1) },
                duration: start.elapsed(),
                prove_duration: None,
                proof_written: false,
                prove_status: None,
                verify_status: None,
            });
        }

        // Prove
        let prove_start = Instant::now();
        let prove_result = zkvm.prove(&Input::new(), ProofKind::Compressed);
        let prove_duration = prove_start.elapsed();

        let (prove_status, proof) = match prove_result {
            Ok((_pv, proof, _report)) => ("success".to_string(), Some(proof)),
            Err(e) => {
                eprintln!("prove failed for {}: {e}", elf_path.display());
                ("failed".to_string(), None)
            }
        };

        if mode == Mode::Prove || proof.is_none() {
            return Ok(RunResult {
                passed,
                exit_code: Some(0),
                duration: start.elapsed(),
                prove_duration: Some(prove_duration),
                proof_written: proof.is_some(),
                prove_status: Some(prove_status),
                verify_status: None,
            });
        }

        // Verify
        let proof = proof.unwrap();
        let verify_result = zkvm.verify(&proof);
        let verify_status = match verify_result {
            Ok(_pv) => "success".to_string(),
            Err(e) => {
                eprintln!("verify failed for {}: {e}", elf_path.display());
                "failed".to_string()
            }
        };

        Ok(RunResult {
            passed,
            exit_code: Some(0),
            duration: start.elapsed(),
            prove_duration: Some(prove_duration),
            proof_written: true,
            prove_status: Some(prove_status),
            verify_status: Some(verify_status),
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
