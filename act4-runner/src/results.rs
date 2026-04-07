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
    pub proved: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prove_failed: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verified: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verify_failed: Option<u32>,
}

/// Detailed results for a test suite run — tests grouped by outcome.
#[derive(Serialize)]
pub struct Results {
    pub zkvm: String,
    pub suite: String,
    pub total: u32,
    pub passed: Vec<String>,
    pub failed: Vec<String>,
    pub prove_failed: Vec<String>,
    pub verify_failed: Vec<String>,
}

/// A single test result entry (internal, used as input to write_results).
pub struct TestEntry {
    pub name: String,
    pub extension: String,
    pub passed: bool,
    pub prove_duration_secs: Option<f64>,
    pub proof_written: Option<bool>,
    pub prove_status: Option<String>,
    pub verify_status: Option<String>,
}

/// Write summary and results JSON files to `dir`.
///
/// Produces two files:
/// - `summary-act4-{label}.json` — aggregate pass/fail counts
/// - `results-act4-{label}.json` — tests grouped by outcome (passed/failed/prove_failed/verify_failed)
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

    let total = sorted.len() as u32;
    let timestamp = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    // Classify tests by outcome
    let mut passed_names = Vec::new();
    let mut failed_names = Vec::new();
    let mut prove_failed_names = Vec::new();
    let mut verify_failed_names = Vec::new();

    for e in &sorted {
        if !e.passed {
            failed_names.push(e.name.clone());
        } else if e.prove_status.as_deref() == Some("failed") {
            prove_failed_names.push(e.name.clone());
        } else if e.verify_status.as_deref() == Some("failed") {
            verify_failed_names.push(e.name.clone());
        } else {
            passed_names.push(e.name.clone());
        }
    }

    let passed_count = passed_names.len() as u32;
    let failed_count = failed_names.len() as u32;

    // Compute prove/verify aggregates for summary
    let has_prove = sorted
        .iter()
        .any(|e| e.prove_status.is_some());
    let proved = sorted
        .iter()
        .filter(|e| e.prove_status.as_deref() == Some("success"))
        .count() as u32;
    let prove_failed_count = prove_failed_names.len() as u32;
    let verified = sorted
        .iter()
        .filter(|e| e.verify_status.as_deref() == Some("success"))
        .count() as u32;
    let verify_failed_count = verify_failed_names.len() as u32;
    let has_verify = verified + verify_failed_count > 0;

    // Write summary
    let summary = Summary {
        zkvm: zkvm.to_owned(),
        suite: suite.to_owned(),
        timestamp: timestamp.clone(),
        passed: passed_count,
        failed: failed_count,
        total,
        proved: if has_prove { Some(proved) } else { None },
        prove_failed: if has_prove { Some(prove_failed_count) } else { None },
        verified: if has_verify { Some(verified) } else { None },
        verify_failed: if has_verify { Some(verify_failed_count) } else { None },
    };
    let summary_path = dir.join(format!("summary-act4-{label}.json"));
    let summary_json =
        serde_json::to_string_pretty(&summary).context("failed to serialize summary")?;
    std::fs::write(&summary_path, format!("{summary_json}\n"))
        .with_context(|| format!("failed to write {}", summary_path.display()))?;

    // Write results
    let results = Results {
        zkvm: zkvm.to_owned(),
        suite: suite.to_owned(),
        total,
        passed: passed_names,
        failed: failed_names,
        prove_failed: prove_failed_names,
        verify_failed: verify_failed_names,
    };
    let results_path = dir.join(format!("results-act4-{label}.json"));
    let results_json =
        serde_json::to_string_pretty(&results).context("failed to serialize results")?;
    std::fs::write(&results_path, format!("{results_json}\n"))
        .with_context(|| format!("failed to write {}", results_path.display()))?;

    Ok(())
}
