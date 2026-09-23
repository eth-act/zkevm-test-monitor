//! act-extra suite: C guests checked through their public output.
//!
//! Each ELF may have sidecars next to it: `<stem>.input` holds the private
//! input bytes (default: empty) and `<stem>.expected` holds the expected public
//! output bytes (default: the verdict `PASS`). A test passes when the emulator
//! finishes cleanly and its public output matches the expected bytes.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Instant;

use anyhow::{Context, Result};

use crate::backends::RunResult;

/// Expected public output of a self-checking guest that passed.
const PASS_VERDICT: &[u8] = b"PASS";

/// Show at most this many bytes of output in a failure detail.
const DETAIL_BYTES: usize = 48;

pub struct ExtraResult {
    pub run: RunResult,
    /// Why the test failed; `None` when it passed.
    pub detail: Option<String>,
}

struct Sidecars {
    input: Vec<u8>,
    expected: Vec<u8>,
}

fn load_sidecars(elf_path: &Path) -> Result<Sidecars> {
    let read_optional = |ext: &str| -> Result<Option<Vec<u8>>> {
        let path = elf_path.with_extension(ext);
        if path.exists() {
            let bytes = std::fs::read(&path).with_context(|| format!("failed to read {}", path.display()))?;
            Ok(Some(bytes))
        } else {
            Ok(None)
        }
    };
    Ok(Sidecars {
        input: read_optional("input")?.unwrap_or_default(),
        expected: read_optional("expected")?.unwrap_or_else(|| PASS_VERDICT.to_vec()),
    })
}

/// Encode input for ziskemu: one record of `[u64 LE length][data, zero-padded to 8 bytes]`.
pub fn zisk_frame_input(data: &[u8]) -> Vec<u8> {
    let mut framed = Vec::with_capacity(8 + data.len() + 7);
    framed.extend_from_slice(&(data.len() as u64).to_le_bytes());
    framed.extend_from_slice(data);
    framed.resize(framed.len().next_multiple_of(8), 0);
    framed
}

/// Compare output from a zkVM whose public output is a fixed-size, zero-padded
/// area (ZisK: 64 u32 slots). The output carries no length, so trailing zero
/// bytes after the expected stream cannot be told apart from padding.
pub fn matches_zero_padded(actual: &[u8], expected: &[u8]) -> bool {
    expected.len() <= actual.len()
        && actual[..expected.len()] == *expected
        && actual[expected.len()..].iter().all(|&b| b == 0)
}

/// Describe an output mismatch, decoding a guest `FAIL` verdict and its
/// optional text label when present.
pub fn describe_mismatch(actual: &[u8], expected: &[u8]) -> String {
    if actual.len() >= 8 && &actual[..4] == b"FAIL" {
        let id = u32::from_le_bytes(actual[4..8].try_into().unwrap());
        let label: String = actual[8..]
            .iter()
            .take_while(|&&b| b != 0)
            .map(|&b| if b.is_ascii_graphic() || b == b' ' { b as char } else { '?' })
            .collect();
        return if label.is_empty() {
            format!("guest check {id} failed")
        } else {
            format!("guest check {id} failed: {label}")
        };
    }
    let shown = actual.len() - actual.iter().rev().take_while(|&&b| b == 0).count();
    let mut detail = format!(
        "output mismatch: expected {} bytes {}, got {}",
        expected.len(),
        hex_prefix(expected),
        hex_prefix(&actual[..shown]),
    );
    if expected.len() > actual.len() {
        detail.push_str(&format!(" (output area holds only {} bytes)", actual.len()));
    }
    detail
}

fn hex_prefix(bytes: &[u8]) -> String {
    let hex: String = bytes.iter().take(DETAIL_BYTES).map(|b| format!("{b:02x}")).collect();
    if bytes.is_empty() {
        "(empty)".to_owned()
    } else if bytes.len() > DETAIL_BYTES {
        format!("{hex}…")
    } else {
        hex
    }
}

/// Run one act-extra ELF through `ziskemu` with its sidecars.
pub fn run_zisk_extra(ziskemu: &Path, elf_path: &Path) -> ExtraResult {
    let start = Instant::now();
    let (passed, exit_code, detail) = match zisk_extra_outcome(ziskemu, elf_path) {
        Ok((exit_code, None)) => (true, exit_code, None),
        Ok((exit_code, Some(detail))) => (false, exit_code, Some(detail)),
        Err(e) => (false, None, Some(format!("runner error: {e:#}"))),
    };
    ExtraResult {
        run: RunResult {
            passed,
            exit_code,
            duration: start.elapsed(),
            prove_duration: None,
            proof_written: false,
            prove_status: None,
            verify_status: None,
        },
        detail,
    }
}

fn zisk_extra_outcome(ziskemu: &Path, elf_path: &Path) -> Result<(Option<i32>, Option<String>)> {
    let sidecars = load_sidecars(elf_path)?;
    let tmp = tempfile::tempdir().context("failed to create temp dir")?;
    let input_path: PathBuf = tmp.path().join("input.bin");
    let output_path: PathBuf = tmp.path().join("output.bin");
    std::fs::write(&input_path, zisk_frame_input(&sidecars.input))?;

    let output = Command::new(ziskemu)
        .arg("-e")
        .arg(elf_path)
        .arg("-i")
        .arg(&input_path)
        .arg("-o")
        .arg(&output_path)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .with_context(|| format!("failed to run {}", ziskemu.display()))?;

    let exit_code = output.status.code();
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() || stderr.contains("finished with error") {
        let reason = emulator_error_reason(&stderr);
        let exit = exit_code.map_or_else(|| "signal".to_owned(), |c| c.to_string());
        return Ok((exit_code, Some(format!("emulator error (exit {exit}): {reason}"))));
    }

    let actual = std::fs::read(&output_path).context("emulator wrote no output file")?;
    if matches_zero_padded(&actual, &sidecars.expected) {
        Ok((exit_code, None))
    } else {
        Ok((exit_code, Some(describe_mismatch(&actual, &sidecars.expected))))
    }
}

/// Run one act-extra ELF through `sp1-extra-executor` with its sidecars.
///
/// The executor pushes the input as one SP1 stdin chunk and writes the raw
/// public-values stream, which has an exact length, so the output must equal
/// the expected bytes.
pub fn run_sp1_extra(executor: &Path, elf_path: &Path) -> ExtraResult {
    let start = Instant::now();
    let (passed, exit_code, detail) = match sp1_extra_outcome(executor, elf_path) {
        Ok((exit_code, None)) => (true, exit_code, None),
        Ok((exit_code, Some(detail))) => (false, exit_code, Some(detail)),
        Err(e) => (false, None, Some(format!("runner error: {e:#}"))),
    };
    ExtraResult {
        run: RunResult {
            passed,
            exit_code,
            duration: start.elapsed(),
            prove_duration: None,
            proof_written: false,
            prove_status: None,
            verify_status: None,
        },
        detail,
    }
}

fn sp1_extra_outcome(executor: &Path, elf_path: &Path) -> Result<(Option<i32>, Option<String>)> {
    let sidecars = load_sidecars(elf_path)?;
    let tmp = tempfile::tempdir().context("failed to create temp dir")?;
    let input_path: PathBuf = tmp.path().join("input.bin");
    let output_path: PathBuf = tmp.path().join("public-values.bin");
    std::fs::write(&input_path, &sidecars.input)?;

    let output = Command::new(executor)
        .arg(elf_path)
        .arg(&input_path)
        .arg(&output_path)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .with_context(|| format!("failed to run {}", executor.display()))?;

    let exit_code = output.status.code();
    if !output.status.success() {
        let reason = emulator_error_reason(&String::from_utf8_lossy(&output.stderr));
        let exit = exit_code.map_or_else(|| "signal".to_owned(), |c| c.to_string());
        return Ok((exit_code, Some(format!("executor error (exit {exit}): {reason}"))));
    }

    let actual = std::fs::read(&output_path).context("executor wrote no public values")?;
    if actual == sidecars.expected {
        Ok((exit_code, None))
    } else {
        Ok((exit_code, Some(describe_exact_mismatch(&actual, &sidecars.expected))))
    }
}

/// Run one act-extra ELF through `openvm-extra-executor` with its sidecars.
///
/// The executor passes the input as one OpenVM input vector and writes the
/// user public values. With ere's VM config these are a fixed area of 256
/// bytes with zero padding, so the output is compared as for ZisK.
pub fn run_openvm_extra(executor: &Path, elf_path: &Path) -> ExtraResult {
    let start = Instant::now();
    let (passed, exit_code, detail) = match openvm_extra_outcome(executor, elf_path) {
        Ok((exit_code, None)) => (true, exit_code, None),
        Ok((exit_code, Some(detail))) => (false, exit_code, Some(detail)),
        Err(e) => (false, None, Some(format!("runner error: {e:#}"))),
    };
    ExtraResult {
        run: RunResult {
            passed,
            exit_code,
            duration: start.elapsed(),
            prove_duration: None,
            proof_written: false,
            prove_status: None,
            verify_status: None,
        },
        detail,
    }
}

fn openvm_extra_outcome(executor: &Path, elf_path: &Path) -> Result<(Option<i32>, Option<String>)> {
    let sidecars = load_sidecars(elf_path)?;
    let tmp = tempfile::tempdir().context("failed to create temp dir")?;
    let input_path: PathBuf = tmp.path().join("input.bin");
    let output_path: PathBuf = tmp.path().join("public-values.bin");
    std::fs::write(&input_path, &sidecars.input)?;

    let output = Command::new(executor)
        .arg(elf_path)
        .arg(&input_path)
        .arg(&output_path)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .with_context(|| format!("failed to run {}", executor.display()))?;

    let exit_code = output.status.code();
    if !output.status.success() {
        let reason = emulator_error_reason(&String::from_utf8_lossy(&output.stderr));
        let exit = exit_code.map_or_else(|| "signal".to_owned(), |c| c.to_string());
        return Ok((exit_code, Some(format!("executor error (exit {exit}): {reason}"))));
    }

    let actual = std::fs::read(&output_path).context("executor wrote no public values")?;
    if matches_zero_padded(&actual, &sidecars.expected) {
        Ok((exit_code, None))
    } else {
        Ok((exit_code, Some(describe_mismatch(&actual, &sidecars.expected))))
    }
}

/// Like `describe_mismatch`, but give the output length instead of the
/// fixed-area note, since an exact comparison can fail on trailing zero bytes
/// that the hex prefix hides.
fn describe_exact_mismatch(actual: &[u8], expected: &[u8]) -> String {
    let detail = describe_mismatch(actual, expected);
    if actual.starts_with(b"FAIL") && actual.len() >= 8 {
        return detail;
    }
    let detail = detail.split(" (output area").next().unwrap_or_default();
    format!("{detail} ({} bytes)", actual.len())
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

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn zero_padded_comparison() {
        let mut area = vec![0u8; 16];
        area[..4].copy_from_slice(b"PASS");
        assert!(matches_zero_padded(&area, b"PASS"));
        assert!(!matches_zero_padded(&area, b"PAS"));
        assert!(!matches_zero_padded(&area, b"FAIL"));
        assert!(!matches_zero_padded(&area, &[1u8; 17]));
        assert!(matches_zero_padded(&[0u8; 16], b""));
    }

    #[test]
    fn describes_guest_failure_and_mismatch() {
        let mut area = vec![0u8; 16];
        area[..4].copy_from_slice(b"FAIL");
        area[4..8].copy_from_slice(&42u32.to_le_bytes());
        assert_eq!(describe_mismatch(&area, b"PASS"), "guest check 42 failed");
        area[8..11].copy_from_slice(b"abc");
        assert_eq!(describe_mismatch(&area, b"PASS"), "guest check 42 failed: abc");

        let detail = describe_mismatch(&[0xab, 0, 0, 0], &[1u8; 5]);
        assert!(detail.contains("got ab"), "{detail}");
        assert!(detail.contains("holds only 4 bytes"), "{detail}");
    }

    #[test]
    fn exact_mismatch_reports_length() {
        let detail = describe_exact_mismatch(b"PASS\0", b"PASS");
        assert!(detail.ends_with("(5 bytes)"), "{detail}");
        let detail = describe_exact_mismatch(&[1u8; 3], &[1u8; 4]);
        assert!(!detail.contains("output area"), "{detail}");
        assert!(detail.ends_with("(3 bytes)"), "{detail}");
        let mut fail = b"FAIL".to_vec();
        fail.extend_from_slice(&7u32.to_le_bytes());
        assert_eq!(describe_exact_mismatch(&fail, b"PASS"), "guest check 7 failed");
    }
}
