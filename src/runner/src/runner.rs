use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

use rayon::prelude::*;

use crate::zkvm_backends::{Execution, Mode, PassHalt, RunResult, Termination, Zkvm};
use crate::io_and_expected_failures::{self, IoVectors, Outcome};

/// The test suite. It sets the defaults of the test vectors (see `crate::io_and_expected_failures`);
/// the zkVM backends do not depend on it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Suite {
    /// The ACT4 ISA tests (`--suite act4-*`): no defaults.
    Isa,
    /// The eth-act standards tests (`--suite eth-act-standards`): a missing
    /// input is empty, and a test without an expected output must write `PASS`.
    Standards,
}

impl Suite {
    /// The suite of a `--suite` name.
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "eth-act-standards" => Some(Suite::Standards),
            _ if name.starts_with("act4-") => Some(Suite::Isa),
            _ => None,
        }
    }
}

/// Check that the zkVM can run in `mode`: proving needs its prover tools.
pub fn check_mode(zkvm: &dyn Zkvm, mode: Mode) -> anyhow::Result<()> {
    if mode != Mode::Execute && !zkvm.can_prove() {
        anyhow::bail!("zkvm '{}' has no prover tools for mode {mode:?}", zkvm.name());
    }
    Ok(())
}

/// Run the ELFs through the zkVM backend (see `run_one`).
pub fn run_tests(
    zkvm: &dyn Zkvm,
    suite: Suite,
    elfs: &[PathBuf],
    jobs: usize,
    mode: Mode,
) -> Vec<(PathBuf, RunResult)> {
    run_elfs(elfs, jobs, |elf_path| run_one(zkvm, suite, elf_path, mode))
}

/// Find the ELF files in `elf_dir` (searched recursively) in alphabetical
/// order, and keep the ones that `select` picks (all of them when it is empty).
///
/// `select` holds words separated by spaces or commas. A test's name is its
/// ELF's file stem and its group is the ELF's parent directory. A word that is
/// exactly a test's or a group's name picks only that test or group. Any other
/// word is a pattern on the test names: a glob with `*` and `?`, else a
/// substring. A word that picks no test is an error.
pub fn find_elfs(elf_dir: &Path, select: &[String]) -> anyhow::Result<Vec<PathBuf>> {
    let mut elfs = discover_elfs(elf_dir);
    elfs.sort();
    let words: Vec<&str> = select.iter().flat_map(|s| s.split([' ', ','])).filter(|w| !w.is_empty()).collect();
    if words.is_empty() {
        return Ok(elfs);
    }

    let file_name = |path: Option<&Path>| path.and_then(Path::file_name).map(|n| n.to_string_lossy().into_owned());
    let tests: Vec<(String, String)> = elfs
        .iter()
        .map(|elf| {
            let name = elf.file_stem().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            (name, file_name(elf.parent()).unwrap_or_default())
        })
        .collect();
    let mut picked = vec![false; elfs.len()];
    for word in words {
        let exact = tests.iter().any(|(name, group)| name == word || group == word);
        let mut found = false;
        for ((name, group), picked) in tests.iter().zip(&mut picked) {
            let hit = if exact { name == word || group == word } else { pattern_matches(word, name) };
            if hit {
                *picked = true;
                found = true;
            }
        }
        if !found {
            anyhow::bail!("no test in {} matches '{word}'", elf_dir.display());
        }
    }
    Ok(elfs.into_iter().zip(picked).filter_map(|(elf, picked)| picked.then_some(elf)).collect())
}

/// Whether `pattern` matches `name`: as a glob when it has `*` (any characters)
/// or `?` (one character), else as a substring.
fn pattern_matches(pattern: &str, name: &str) -> bool {
    fn glob(pattern: &[u8], name: &[u8]) -> bool {
        match pattern.split_first() {
            None => name.is_empty(),
            Some((b'*', rest)) => (0..=name.len()).any(|i| glob(rest, &name[i..])),
            Some((b'?', rest)) => !name.is_empty() && glob(rest, &name[1..]),
            Some((c, rest)) => name.first() == Some(c) && glob(rest, &name[1..]),
        }
    }
    if pattern.contains(['*', '?']) {
        glob(pattern.as_bytes(), name.as_bytes())
    } else {
        name.contains(pattern)
    }
}

/// Run each ELF with `run` on `jobs` threads, and return the results in the
/// order of `elfs`. The ere backend (`--features ere`) uses this directly with
/// its own `run`.
pub fn run_elfs(
    elfs: &[PathBuf],
    jobs: usize,
    run: impl Fn(&Path) -> RunResult + Sync,
) -> Vec<(PathBuf, RunResult)> {
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
                let result = run(elf_path);
                let done = completed.fetch_add(1, Ordering::Relaxed) + 1;
                report_progress(done, total, elf_path, &result);
                (elf_path.clone(), result)
            })
            .collect()
    })
}

/// Run one ELF with its test vectors (see `crate::io_and_expected_failures`), prove it in the prove
/// modes, and apply its expected outcome. A `distinct` test runs twice (see `judge_distinct`).
pub fn run_one(zkvm: &dyn Zkvm, suite: Suite, elf_path: &Path, mode: Mode) -> RunResult {
    let start = Instant::now();
    let vectors = match IoVectors::load(elf_path, suite == Suite::Standards) {
        Ok(vectors) => vectors,
        Err(e) => return RunResult::host_error(start, None, format!("runner error: {e:#}")),
    };
    if vectors.has_io() && !zkvm.supports_io() {
        let detail = format!("the {} backend cannot feed .input or check .expected", zkvm.name());
        return RunResult::host_error(start, None, detail);
    }

    let distinct = vectors.outcome == Outcome::Distinct;
    let execution = zkvm.execute(elf_path, vectors.input.as_deref());
    let output = execution.output.as_ref().map(|output| output.bytes.clone());
    // A distinct test writes its draws, not `PASS`.
    let pass_output = suite == Suite::Standards && !distinct;
    let mut result = judge(execution, vectors.expected.as_deref(), pass_output, start);
    if distinct && result.passed {
        let second = zkvm.execute(elf_path, vectors.input.as_deref());
        result = judge_distinct(output.clone().unwrap_or_default(), second, vectors.expected.as_deref(), start);
    }

    // Prove only an execution that passed, and check that the proof proves its output. A
    // distinct test's proof comes from a new execution, whose output differs by design.
    if mode != Mode::Execute && result.passed {
        let output = if distinct { None } else { output.as_deref() };
        result = match zkvm.prove(elf_path, vectors.input.as_deref(), output, mode == Mode::Full) {
            Ok(proof) => RunResult { duration: start.elapsed(), ..result.with_proof(proof) },
            Err(e) => {
                eprintln!("error running {}: {e}", elf_path.display());
                RunResult::host_error(start, None, format!("runner error: {e:#}"))
            }
        };
    }
    apply_outcome(result, vectors.outcome)
}

/// Run one ELF through a backend that runs its own stages (the ere backend,
/// `run`), with the same test vectors and expected outcome as `run_one`. `run`
/// gets the vectors: the ere backend feeds `.input` and checks `.expected` for
/// the standards suite only, so an ISA test with `.input` or `.expected` is a
/// host error. `.outcome` applies. `name` names the backend in a failure detail.
pub fn run_one_with(
    name: &str,
    suite: Suite,
    elf_path: &Path,
    run: impl FnOnce(&Path, &IoVectors) -> RunResult,
) -> RunResult {
    let start = Instant::now();
    let vectors = match IoVectors::load(elf_path, suite == Suite::Standards) {
        Ok(vectors) => vectors,
        Err(e) => return RunResult::host_error(start, None, format!("runner error: {e:#}")),
    };
    if suite == Suite::Isa && vectors.has_io() {
        return RunResult::host_error(start, None, format!("the {name} backend cannot feed .input or check .expected"));
    }
    if vectors.outcome == Outcome::Distinct {
        return RunResult::host_error(start, None, format!("the {name} backend cannot run a distinct test"));
    }
    let result = run(elf_path, &vectors);
    apply_outcome(result, vectors.outcome)
}

/// Judge an execution against the test's expected output. This is the one
/// verdict for both suites and every zkVM.
///
/// - Only a successful termination can pass; the execution's detail says why
///   another one failed.
/// - With an expected output, the public output must match it in the zkVM's
///   output area.
/// - Without one, the pass halt decides when the zkVM reports it (ZisK's
///   `PASS` marker). Otherwise, with `pass_output` (a self-checking standards
///   test), the output must be `PASS`: on SP1 and OpenVM the pass halt is exit
///   code 0, like a return from `main` (tests/eth-act-standards/include/checks.h).
///   Without `pass_output`, the successful termination passes.
pub fn judge(execution: Execution, expected: Option<&[u8]>, pass_output: bool, start: Instant) -> RunResult {
    let detail = match execution.termination {
        Termination::Success => output_mismatch(&execution, expected, pass_output),
        Termination::Failure { .. } | Termination::HostError => execution.detail,
    };
    RunResult::executed(start, execution.exit_code, execution.termination, detail)
}

/// Judge the second execution of a `distinct` test. It must also pass, and its
/// public output must differ from `first_output`.
fn judge_distinct(first_output: Vec<u8>, second: Execution, expected: Option<&[u8]>, start: Instant) -> RunResult {
    let second_output = second.output.as_ref().map(|output| output.bytes.clone()).unwrap_or_default();
    let result = judge(second, expected, false, start);
    if !result.passed {
        return result;
    }
    let detail = io_and_expected_failures::check_distinct(&first_output, &second_output);
    RunResult { passed: detail.is_none(), detail, ..result }
}

/// Why a successful execution's output fails the test, or `None` if it passes.
fn output_mismatch(execution: &Execution, expected: Option<&[u8]>, pass_output: bool) -> Option<String> {
    let expected = match (expected, &execution.pass_halt) {
        (Some(expected), _) => expected,
        (None, PassHalt::Reached) => return None,
        (None, PassHalt::Missed(reason)) => return Some(reason.clone()),
        (None, PassHalt::Unknown) if pass_output => io_and_expected_failures::PASS_OUTPUT,
        (None, PassHalt::Unknown) => return None,
    };
    match &execution.output {
        Some(output) => output.mismatch(expected),
        None => Some("the zkVM reports no public output".to_owned()),
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
        // sp1 is not listed: its execute runs parallel via the default, while
        // prove/full runs are forced to 1 job in main.rs.
        "openvm" => 1,
        "zisk" => {
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
    use crate::zkvm_backends::{OutputArea, Proof, PublicOutput};

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
    fn expected_distinct_keeps_the_result() {
        let same = "two executions gave the same public output 00";
        assert!(!apply_outcome(result(Termination::Success, Some(same)), Outcome::Distinct).passed);
        assert!(apply_outcome(result(Termination::Success, None), Outcome::Distinct).passed);
    }

    #[test]
    fn judge_distinct_compares_the_outputs() {
        let run = |bytes: &'static [u8]| execution(Termination::Success, Some((bytes, OutputArea::Exact)), PassHalt::Unknown);
        assert!(judge_distinct(b"ab".to_vec(), run(b"ac"), None, Instant::now()).passed);
        let r = judge_distinct(b"ab".to_vec(), run(b"ab"), None, Instant::now());
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("two executions gave the same public output 6162"));
        let r = judge_distinct(b"ab".to_vec(), execution(failure(None), None, PassHalt::Unknown), None, Instant::now());
        assert_eq!(r.detail.as_deref(), Some("abnormal"));
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

    fn execution(termination: Termination, output: Option<(&[u8], OutputArea)>, pass_halt: PassHalt) -> Execution {
        Execution {
            termination,
            exit_code: None,
            output: output.map(|(bytes, area)| PublicOutput { bytes: bytes.to_vec(), area }),
            pass_halt,
            detail: (termination != Termination::Success).then(|| "abnormal".to_owned()),
        }
    }

    fn verdict(execution: Execution, expected: Option<&[u8]>, suite: Suite) -> RunResult {
        judge(execution, expected, suite == Suite::Standards, Instant::now())
    }

    const PADDED_PASS: &[u8] = b"PASS\0\0\0\0";

    #[test]
    fn judge_isa_tests_on_the_termination() {
        // LambdaVM, OpenVM and SP1: the exit status alone.
        let r = verdict(execution(Termination::Success, None, PassHalt::Unknown), None, Suite::Isa);
        assert!(r.passed);
        let r = verdict(execution(failure(None), None, PassHalt::Unknown), None, Suite::Isa);
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("abnormal"));
        let r = verdict(execution(Termination::HostError, None, PassHalt::Unknown), None, Suite::Isa);
        assert!(!r.passed);

        // ZisK: the PASS marker.
        let zisk = |bytes: &'static [u8], pass_halt| execution(Termination::Success, Some((bytes, OutputArea::ZeroPadded)), pass_halt);
        assert!(verdict(zisk(PADDED_PASS, PassHalt::Reached), None, Suite::Isa).passed);
        let r = verdict(zisk(b"\0\0\0\0", PassHalt::Missed("no marker".to_owned())), None, Suite::Isa);
        assert!(!r.passed);
        assert_eq!(r.detail.as_deref(), Some("no marker"));
    }

    #[test]
    fn judge_self_checking_standards_tests_on_the_pass_output() {
        let run = |bytes: &'static [u8], area| {
            verdict(execution(Termination::Success, Some((bytes, area)), PassHalt::Unknown), None, Suite::Standards)
        };
        // SP1: exactly PASS.
        assert!(run(b"PASS", OutputArea::Exact).passed);
        let r = run(b"PASS\0", OutputArea::Exact);
        assert!(!r.passed);
        assert!(r.detail.unwrap().ends_with("(5 bytes)"));
        assert!(!run(b"", OutputArea::Exact).passed);
        // OpenVM: PASS in a zero-padded area.
        assert!(run(PADDED_PASS, OutputArea::ZeroPadded).passed);
        assert!(!run(b"PASSX\0\0\0", OutputArea::ZeroPadded).passed);

        // ZisK: the PASS marker decides, as for the ISA tests.
        let zisk = |bytes: &'static [u8], pass_halt| {
            let e = execution(Termination::Success, Some((bytes, OutputArea::ZeroPadded)), pass_halt);
            verdict(e, None, Suite::Standards)
        };
        assert!(zisk(PADDED_PASS, PassHalt::Reached).passed);
        let r = zisk(b"\0\0\0\0", PassHalt::Missed("no marker".to_owned()));
        assert_eq!(r.detail.as_deref(), Some("no marker"));

        // Without the output, the standards default cannot pass.
        let r = verdict(execution(Termination::Success, None, PassHalt::Unknown), None, Suite::Standards);
        assert_eq!(r.detail.as_deref(), Some("the zkVM reports no public output"));
    }

    #[test]
    fn judge_the_expected_output_in_both_suites() {
        for suite in [Suite::Isa, Suite::Standards] {
            for pass_halt in [PassHalt::Unknown, PassHalt::Reached, PassHalt::Missed("no marker".to_owned())] {
                let ok = execution(Termination::Success, Some((b"ab\0\0", OutputArea::ZeroPadded)), pass_halt.clone());
                assert!(verdict(ok, Some(b"ab"), suite).passed, "{suite:?} {pass_halt:?}");
                let bad = execution(Termination::Success, Some((b"ab\0\0", OutputArea::Exact)), pass_halt.clone());
                assert!(!verdict(bad, Some(b"ab"), suite).passed, "{suite:?} {pass_halt:?}");
            }
            // A failure does not pass, whatever its output.
            let r = verdict(execution(failure(Some(1)), None, PassHalt::Unknown), Some(b""), suite);
            assert!(!r.passed);
            assert_eq!(r.termination, failure(Some(1)));
        }
    }

    /// A zkVM whose execution and proof are given, and which counts its proofs.
    struct Fake {
        success: bool,
        proof: Option<bool>,
        proofs: AtomicUsize,
    }

    impl Zkvm for Fake {
        fn name(&self) -> &'static str {
            "fake"
        }

        fn supports_io(&self) -> bool {
            false
        }

        fn can_prove(&self) -> bool {
            self.proof.is_some()
        }

        fn execute(&self, _elf_path: &Path, _input: Option<&[u8]>) -> Execution {
            let termination = Termination::from_success(self.success);
            execution(termination, None, PassHalt::Unknown)
        }

        fn prove(&self, _elf_path: &Path, _input: Option<&[u8]>, _output: Option<&[u8]>, verify: bool) -> anyhow::Result<Proof> {
            self.proofs.fetch_add(1, Ordering::Relaxed);
            match self.proof {
                Some(proved) => {
                    Ok(Proof { duration: Duration::ZERO, written: proved, proved, verified: (proved && verify).then_some(true) })
                }
                None => anyhow::bail!("no prover"),
            }
        }
    }

    fn run_fake(success: bool, proof: Option<bool>, mode: Mode) -> (RunResult, usize) {
        let dir = tempfile::tempdir().unwrap();
        let elf = dir.path().join("t.elf");
        let fake = Fake { success, proof, proofs: AtomicUsize::new(0) };
        let r = run_one(&fake, Suite::Isa, &elf, mode);
        (r, fake.proofs.load(Ordering::Relaxed))
    }

    #[test]
    fn the_mode_decides_whether_to_prove() {
        let (r, proofs) = run_fake(true, Some(true), Mode::Execute);
        assert!(r.passed);
        assert_eq!((proofs, r.prove_status, r.verify_status), (0, None, None));

        let (r, proofs) = run_fake(true, Some(true), Mode::Prove);
        assert!(r.passed);
        assert_eq!(proofs, 1);
        assert_eq!((r.prove_status.as_deref(), r.verify_status.as_deref()), (Some("success"), None));

        let (r, _) = run_fake(true, Some(true), Mode::Full);
        assert_eq!((r.prove_status.as_deref(), r.verify_status.as_deref()), (Some("success"), Some("success")));

        // A failed proof keeps the execution's pass; the results file lists it
        // under prove_failed.
        let (r, _) = run_fake(true, Some(false), Mode::Full);
        assert!(r.passed);
        assert_eq!((r.prove_status.as_deref(), r.verify_status.as_deref()), (Some("failed"), None));

        // No proof of an execution that failed.
        let (r, proofs) = run_fake(false, Some(true), Mode::Full);
        assert!(!r.passed);
        assert_eq!((proofs, r.prove_status), (0, None));

        // A prover error is a runner error.
        let (r, _) = run_fake(true, None, Mode::Prove);
        assert!(!r.passed);
        assert_eq!(r.termination, Termination::HostError);
        assert_eq!(r.detail.as_deref(), Some("runner error: no prover"));
        assert_eq!(r.prove_status, None);
    }

    #[test]
    fn a_backend_without_io_rejects_io_vectors() {
        let dir = tempfile::tempdir().unwrap();
        let elf = dir.path().join("t.elf");
        std::fs::write(dir.path().join("t.expected"), b"x").unwrap();
        let fake = Fake { success: true, proof: None, proofs: AtomicUsize::new(0) };
        let r = run_one(&fake, Suite::Isa, &elf, Mode::Execute);
        assert_eq!(r.termination, Termination::HostError);
        assert_eq!(r.detail.as_deref(), Some("the fake backend cannot feed .input or check .expected"));

        // The standards suite gives every test an input.
        std::fs::remove_file(dir.path().join("t.expected")).unwrap();
        let r = run_one(&fake, Suite::Standards, &elf, Mode::Execute);
        assert_eq!(r.termination, Termination::HostError);
        assert!(run_one(&fake, Suite::Isa, &elf, Mode::Execute).passed);
    }

    /// Find the tests that `select` picks among a standards-like ELF tree.
    fn selected(select: &[&str]) -> anyhow::Result<Vec<String>> {
        let dir = tempfile::tempdir().unwrap();
        for test in [
            "io/io-echo",
            "io/io-write-257-bytes",
            "io/io-write-257-bytes-in-pieces",
            "accelerators/accel-bls12-g1-add",
            "accelerators/accel-keccak256",
            "memory/mem-memcpy",
            "memory/mem-link-memcpy",
        ] {
            let elf = dir.path().join(format!("{test}.elf"));
            std::fs::create_dir_all(elf.parent().unwrap()).unwrap();
            std::fs::write(&elf, b"").unwrap();
            std::fs::write(elf.with_extension("input"), b"").unwrap();
        }
        let select: Vec<String> = select.iter().map(|s| s.to_string()).collect();
        let elfs = find_elfs(dir.path(), &select)?;
        Ok(elfs.iter().map(|elf| elf.file_stem().unwrap().to_string_lossy().into_owned()).collect())
    }

    #[test]
    fn selects_tests_by_name_group_or_pattern() {
        assert_eq!(selected(&[]).unwrap().len(), 7);
        // A test name selects only that test, though it is a substring of another.
        assert_eq!(selected(&["io-write-257-bytes"]).unwrap(), ["io-write-257-bytes"]);
        // A group selects its tests (in path order: `-` sorts before `.`).
        assert_eq!(selected(&["io"]).unwrap(), ["io-echo", "io-write-257-bytes-in-pieces", "io-write-257-bytes"]);
        // Other words are globs or substrings of the test names.
        assert_eq!(selected(&["io-write-*"]).unwrap(), ["io-write-257-bytes-in-pieces", "io-write-257-bytes"]);
        assert_eq!(selected(&["accel-?eccak*"]).unwrap(), ["accel-keccak256"]);
        assert_eq!(selected(&["memcpy"]).unwrap(), ["mem-link-memcpy", "mem-memcpy"]);
        assert_eq!(selected(&["*-memcpy"]).unwrap(), ["mem-link-memcpy", "mem-memcpy"]);
        assert_eq!(selected(&["io-*-pieces"]).unwrap(), ["io-write-257-bytes-in-pieces"]);
        // Words separated by spaces or commas, in one value or several.
        let both = ["accel-bls12-g1-add", "io-echo"];
        assert_eq!(selected(&["io-echo bls"]).unwrap(), both);
        assert_eq!(selected(&["io-echo,bls"]).unwrap(), both);
        assert_eq!(selected(&["io-echo", "bls"]).unwrap(), both);
        // Selecting a test twice runs it once.
        assert_eq!(selected(&["io-echo io"]).unwrap().len(), 3);
    }

    #[test]
    fn a_word_that_selects_nothing_is_an_error() {
        let e = selected(&["io-echo", "nosuch"]).unwrap_err();
        assert!(e.to_string().ends_with("matches 'nosuch'"), "{e}");
        assert!(selected(&["io-echo*x"]).is_err());
        // Only the ELF names count, not the test vectors.
        assert!(selected(&["input"]).is_err());
    }

    #[test]
    fn parses_suite_names() {
        assert_eq!(Suite::from_name("eth-act-standards"), Some(Suite::Standards));
        for name in ["act4-full", "act4-standard", "act4-native"] {
            assert_eq!(Suite::from_name(name), Some(Suite::Isa));
        }
        assert_eq!(Suite::from_name("standards"), None);
    }

    #[test]
    fn run_one_with_applies_vectors_and_outcome() {
        let dir = tempfile::tempdir().unwrap();
        let elf = dir.path().join("t.elf");
        std::fs::write(&elf, b"").unwrap();
        let run = |termination: Termination| {
            run_one_with("ere-sp1", Suite::Isa, &elf, |_, _| result(termination, Some("detail")))
        };

        std::fs::write(dir.path().join("t.outcome"), "fail\n").unwrap();
        assert!(run(Termination::Failure { code: None }).passed);
        assert!(!run(Termination::HostError).passed);
        assert!(!run(Termination::Success).passed);

        std::fs::write(dir.path().join("t.input"), b"x").unwrap();
        let r = run(Termination::Failure { code: None });
        assert_eq!(r.termination, Termination::HostError);
        assert_eq!(r.detail.as_deref(), Some("the ere-sp1 backend cannot feed .input or check .expected"));

        // A standards test gets its vectors.
        let r = run_one_with("ere-sp1", Suite::Standards, &elf, |_, vectors| {
            assert_eq!(vectors.input.as_deref(), Some(&b"x"[..]));
            result(Termination::Failure { code: None }, None)
        });
        assert!(r.passed);
    }
}
