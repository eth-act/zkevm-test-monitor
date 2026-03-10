use std::path::Path;

use anyhow::{Context, Result};
use chrono::Utc;
use serde::Serialize;

/// High-level pass/fail summary for a test suite run.
#[derive(Serialize)]
pub struct Summary {
    pub zkvm: String,
    pub suite: String,
    pub timestamp: String,
    pub passed: u32,
    pub failed: u32,
    pub total: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_prove_secs: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proved: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prove_failed: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verified: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verify_failed: Option<u32>,
}

/// Detailed per-test results for a test suite run.
#[derive(Serialize)]
pub struct Results {
    pub zkvm: String,
    pub suite: String,
    pub tests: Vec<TestEntry>,
}

/// A single test result entry.
#[derive(Serialize)]
pub struct TestEntry {
    pub name: String,
    pub extension: String,
    pub passed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prove_duration_secs: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proof_written: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prove_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verify_status: Option<String>,
}

/// Write summary and results JSON files to `dir`.
///
/// Produces two files:
/// - `summary-act4-{label}.json` — aggregate pass/fail counts
/// - `results-act4-{label}.json` — per-test detail
///
/// The `extension` field on each `TestEntry` is the parent directory name of the
/// ELF file (e.g. `"I"` for `elfs/I/I-add-00.elf`). Entries are sorted by
/// (extension, name).
pub fn write_results(
    dir: &Path,
    label: &str,
    zkvm: &str,
    suite: &str,
    entries: &[TestEntry],
) -> Result<()> {
    // Sort entries by (extension, name)
    let mut sorted: Vec<&TestEntry> = entries.iter().collect();
    sorted.sort_by(|a, b| {
        a.extension
            .cmp(&b.extension)
            .then_with(|| a.name.cmp(&b.name))
    });

    let passed = sorted.iter().filter(|e| e.passed).count() as u32;
    let total = sorted.len() as u32;
    let failed = total - passed;

    let timestamp = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    // Compute total prove time if any tests have prove durations
    let total_prove_secs: Option<f64> = {
        let sum: f64 = sorted
            .iter()
            .filter_map(|e| e.prove_duration_secs)
            .sum();
        if sum > 0.0 { Some(sum) } else { None }
    };

    // Compute prove/verify aggregates (only if any tests have these statuses)
    let proved = sorted
        .iter()
        .filter(|e| e.prove_status.as_deref() == Some("success"))
        .count() as u32;
    let prove_failed = sorted
        .iter()
        .filter(|e| e.prove_status.as_deref() == Some("failed"))
        .count() as u32;
    let has_prove = proved + prove_failed > 0;

    let verified = sorted
        .iter()
        .filter(|e| e.verify_status.as_deref() == Some("success"))
        .count() as u32;
    let verify_failed = sorted
        .iter()
        .filter(|e| e.verify_status.as_deref() == Some("failed"))
        .count() as u32;
    let has_verify = verified + verify_failed > 0;

    // Write summary
    let summary = Summary {
        zkvm: zkvm.to_owned(),
        suite: suite.to_owned(),
        timestamp: timestamp.clone(),
        passed,
        failed,
        total,
        total_prove_secs,
        proved: if has_prove { Some(proved) } else { None },
        prove_failed: if has_prove { Some(prove_failed) } else { None },
        verified: if has_verify { Some(verified) } else { None },
        verify_failed: if has_verify { Some(verify_failed) } else { None },
    };
    let summary_path = dir.join(format!("summary-act4-{label}.json"));
    let summary_json =
        serde_json::to_string_pretty(&summary).context("failed to serialize summary")?;
    std::fs::write(&summary_path, format!("{summary_json}\n"))
        .with_context(|| format!("failed to write {}", summary_path.display()))?;

    // Write results — rebuild with sorted order
    let sorted_entries: Vec<TestEntry> = sorted
        .iter()
        .map(|e| TestEntry {
            name: e.name.clone(),
            extension: e.extension.clone(),
            passed: e.passed,
            prove_duration_secs: e.prove_duration_secs,
            proof_written: e.proof_written,
            prove_status: e.prove_status.clone(),
            verify_status: e.verify_status.clone(),
        })
        .collect();

    let results = Results {
        zkvm: zkvm.to_owned(),
        suite: suite.to_owned(),
        tests: sorted_entries,
    };
    let results_path = dir.join(format!("results-act4-{label}.json"));
    let results_json =
        serde_json::to_string_pretty(&results).context("failed to serialize results")?;
    std::fs::write(&results_path, format!("{results_json}\n"))
        .with_context(|| format!("failed to write {}", results_path.display()))?;

    Ok(())
}
