use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

use rayon::prelude::*;

use crate::backends::{Backend, Mode, RunResult, Termination};
use crate::io_and_expected_failures::{IoVectors, Outcome};

/// Discover all ELF files in `elf_dir` recursively, run each through the backend
/// in parallel, and return results in deterministic (alphabetical) order.
pub fn run_tests(backend: &Backend, elf_dir: &Path, jobs: usize, mode: Mode) -> Vec<(PathBuf, RunResult)> {
    let mut elfs = discover_elfs(elf_dir);
    elfs.sort();
    let total = elfs.len();

    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(jobs)
        .build()
        .expect("failed to build rayon thread pool");

    // Per-test progress is streamed to stderr as each ELF finishes so a run
    // shows steady output instead of going silent until the final summary.
    // With parallel jobs the completion order is not sorted, hence the counter.
    let completed = AtomicUsize::new(0);

    pool.install(|| {
        elfs.par_iter()
            .map(|elf_path| {
                let result = run_one(backend, elf_path, mode);
                let done = completed.fetch_add(1, Ordering::Relaxed) + 1;
                report_progress(done, total, elf_path, &result);
                (elf_path.clone(), result)
            })
            .collect()
    })
}

/// Run one ELF with its test vectors (see `crate::io_and_expected_failures`) and apply its expected outcome.
pub fn run_one(backend: &Backend, elf_path: &Path, mode: Mode) -> RunResult {
    match IoVectors::load(elf_path, backend.is_standards()) {
        Ok(vectors) => apply_outcome(backend.run_elf(elf_path, mode, &vectors), vectors.outcome),
        Err(e) => RunResult::host_error(Instant::now(), None, format!("runner error: {e:#}")),
    }
}

/// Judge a result against the expected outcome `fail` or `fail <code>`.
///
/// An abnormal termination passes when no code is expected, or when the zkVM
/// reports the expected code. It fails when the zkVM reports another code or
/// no code. A successful termination fails ("did not panic" without an
/// expected code, "did not terminate abnormally" with one). A host error
/// always fails: it is not a guest outcome.
pub fn apply_outcome(result: RunResult, outcome: Outcome) -> RunResult {
    let Outcome::Fail { code: expected } = outcome else {
        return result;
    };
    let detail = match result.termination {
        Termination::HostError => return RunResult { passed: false, ..result },
        Termination::Success => {
            let what = if expected.is_some() { "did not terminate abnormally" } else { "did not panic" };
            Some(match &result.detail {
                Some(detail) => format!("{what}: finished normally ({detail})"),
                None => format!("{what}: finished normally"),
            })
        }
        Termination::Failure { code } => match (expected, code) {
            (None, _) => None,
            (Some(expected), Some(code)) if expected == code => None,
            (Some(expected), Some(code)) => {
                Some(format!("wrong error code: expected {expected}, got {code}"))
            }
            (Some(expected), None) => Some(format!(
                "error code not reported: expected {expected}, the zkVM reported an abnormal termination without a code"
            )),
        },
    };
    RunResult { passed: detail.is_none(), detail, ..result }
}

/// Print a one-line progress report for a finished test to stderr.
///
/// Format: `[ 12/64] PASS I-add-00 (0.01s)`, with `prove=`/`verify=` appended
/// when those stages ran.
fn report_progress(idx: usize, total: usize, elf_path: &Path, result: &RunResult) {
    let name = elf_path
        .file_stem()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown");
    let status = if result.passed { "PASS" } else { "FAIL" };

    let mut detail = String::new();
    if let Some(prove) = &result.prove_status {
        detail.push_str(&format!(" prove={prove}"));
    }
    if let Some(verify) = &result.verify_status {
        detail.push_str(&format!(" verify={verify}"));
    }

    let width = total.to_string().len();
    eprintln!(
        "  [{idx:>width$}/{total}] {status} {name} ({:.2}s){detail}",
        result.duration.as_secs_f64(),
    );
}

/// Recursively discover all `*.elf` files under `dir`.
fn discover_elfs(dir: &Path) -> Vec<PathBuf> {
    let mut results = Vec::new();
    collect_elfs(dir, &mut results);
    results
}

fn collect_elfs(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_elfs(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "elf") {
            out.push(path);
        }
    }
}

/// Determine the default number of parallel jobs for a given ZKVM.
///
/// Zisk is memory-intensive (~8 GB per instance), so we cap based on available
/// memory. OpenVM initializes a large thread pool per process, so concurrent
/// executors oversubscribe the host and can fail nondeterministically.
pub fn default_jobs(zkvm: &str) -> usize {
    match zkvm {
        // sp1-prove is not listed: its native (execute) suite runs parallel via the
        // default, while its target (prove/full) suite is forced to 1 job in main.rs.
        "openvm" | "openvm-prove" | "openvm-standards" => 1,
        "zisk-prove" | "zisk" | "zisk-standards" => {
            let mem_bytes = read_available_memory_bytes().unwrap_or(0);
            // Use 80% of available memory, 8 GB per instance
            let by_mem = (mem_bytes as f64 * 0.8 / 8_000_000_000.0) as usize;
            by_mem.clamp(1, 24)
        }
        _ => std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1),
    }
}

/// Read MemAvailable from /proc/meminfo in bytes.
fn read_available_memory_bytes() -> Option<u64> {
    let content = std::fs::read_to_string("/proc/meminfo").ok()?;
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("MemAvailable:") {
            let kb_str = rest.trim().strip_suffix("kB")?.trim();
            let kb: u64 = kb_str.parse().ok()?;
            return Some(kb * 1024);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn result(termination: Termination, detail: Option<&str>) -> RunResult {
        RunResult {
            passed: termination == Termination::Success && detail.is_none(),
            exit_code: None,
            duration: Duration::ZERO,
            prove_duration: None,
            proof_written: false,
            prove_status: None,
            verify_status: None,
            termination,
            detail: detail.map(str::to_owned),
        }
    }

    const FAIL: Outcome = Outcome::Fail { code: None };
    const FAIL_7: Outcome = Outcome::Fail { code: Some(7) };

    fn failure(code: Option<i32>) -> Termination {
        Termination::Failure { code }
    }

    #[test]
    fn expected_pass_keeps_the_result() {
        let r = apply_outcome(result(failure(None), Some("emulator error")), Outcome::Pass);
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("emulator error"));

        let r = apply_outcome(result(Termination::Success, None), Outcome::Pass);
        assert!(r.passed);
    }

    #[test]
    fn expected_fail_accepts_abnormal_termination_with_any_code() {
        for code in [None, Some(1), Some(7)] {
            let r = apply_outcome(result(failure(code), Some("guest terminated abnormally")), FAIL);
            assert!(r.passed, "{code:?}");
            assert_eq!(r.detail, None);
        }
    }

    #[test]
    fn expected_fail_rejects_a_normal_finish() {
        let r = apply_outcome(result(Termination::Success, None), FAIL);
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("did not panic: finished normally"));

        let r = apply_outcome(result(Termination::Success, Some("guest check 1 failed: returned")), FAIL);
        assert!(!r.passed);
        assert_eq!(
            r.detail.as_deref(),
            Some("did not panic: finished normally (guest check 1 failed: returned)")
        );
    }

    #[test]
    fn expected_fail_rejects_host_errors() {
        let r = apply_outcome(result(Termination::HostError, Some("runner error: x")), FAIL);
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("runner error: x"));

        let r = apply_outcome(result(Termination::HostError, Some("executor error (exit 2): usage")), FAIL_7);
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("executor error (exit 2): usage"));
    }

    #[test]
    fn expected_code_must_match() {
        let r = apply_outcome(result(failure(Some(7)), Some("guest terminated abnormally")), FAIL_7);
        assert!(r.passed);
        assert_eq!(r.detail, None);

        let r = apply_outcome(result(failure(Some(1)), Some("guest terminated abnormally")), FAIL_7);
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("wrong error code: expected 7, got 1"));
    }

    #[test]
    fn expected_code_must_be_reported() {
        let r = apply_outcome(result(failure(None), Some("emulator error")), FAIL_7);
        assert!(!r.passed);
        assert!(r.detail.as_deref().unwrap().starts_with("error code not reported: expected 7"));
    }

    #[test]
    fn expected_code_rejects_a_normal_finish() {
        let r = apply_outcome(result(Termination::Success, None), FAIL_7);
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("did not terminate abnormally: finished normally"));
    }
}
