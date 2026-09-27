//! Per-ELF test vectors and the checks of a guest's public output.
//!
//! Every ELF may have these files next to it:
//! - `<stem>.input`: the private input bytes;
//! - `<stem>.expected`: the expected public output bytes;
//! - `<stem>.outcome`: `pass` (the default) or `fail`. With `fail`, the guest
//!   must terminate abnormally (panic, failed execution). A normal finish fails
//!   the test with a "did not panic" detail.
//!
//! The standards backends default a missing input to empty and a missing
//! expected output to the verdict `PASS`. The ISA backends have no defaults, so
//! an ISA test without these files runs exactly as before.

use std::path::Path;

use anyhow::{Context, Result, bail};

/// Expected public output of a self-checking guest that passed.
pub const PASS_VERDICT: &[u8] = b"PASS";

/// Show at most this many bytes of output in a failure detail.
const DETAIL_BYTES: usize = 48;

/// The expected way for a guest to terminate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Finish normally (and match the expected output, if any).
    Pass,
    /// Terminate abnormally: panic or failed execution.
    Fail,
}

/// The test vectors of one ELF.
#[derive(Debug, PartialEq, Eq)]
pub struct IoVectors {
    pub input: Option<Vec<u8>>,
    pub expected: Option<Vec<u8>>,
    pub outcome: Outcome,
}

impl IoVectors {
    /// Load the vectors next to `elf_path`. With `standards`, a missing input
    /// is empty and a missing expected output is `PASS`.
    pub fn load(elf_path: &Path, standards: bool) -> Result<Self> {
        let read_optional = |ext: &str| -> Result<Option<Vec<u8>>> {
            let path = elf_path.with_extension(ext);
            if path.exists() {
                let bytes = std::fs::read(&path).with_context(|| format!("failed to read {}", path.display()))?;
                Ok(Some(bytes))
            } else {
                Ok(None)
            }
        };
        let outcome = match read_optional("outcome")? {
            None => Outcome::Pass,
            Some(bytes) => match String::from_utf8_lossy(&bytes).trim() {
                "pass" => Outcome::Pass,
                "fail" => Outcome::Fail,
                other => bail!("unknown outcome '{other}' in {}", elf_path.with_extension("outcome").display()),
            },
        };
        let mut input = read_optional("input")?;
        let mut expected = read_optional("expected")?;
        if standards {
            input.get_or_insert_with(Vec::new);
            expected.get_or_insert_with(|| PASS_VERDICT.to_vec());
        }
        Ok(IoVectors { input, expected, outcome })
    }

    /// Whether the test feeds an input or checks the output.
    pub fn has_io(&self) -> bool {
        self.input.is_some() || self.expected.is_some()
    }
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

/// Like `describe_mismatch`, but give the output length instead of the
/// fixed-area note, since an exact comparison can fail on trailing zero bytes
/// that the hex prefix hides.
pub fn describe_exact_mismatch(actual: &[u8], expected: &[u8]) -> String {
    let detail = describe_mismatch(actual, expected);
    if actual.starts_with(b"FAIL") && actual.len() >= 8 {
        return detail;
    }
    let detail = detail.split(" (output area").next().unwrap_or_default();
    format!("{detail} ({} bytes)", actual.len())
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

/// Pick the most informative stderr line: the message of a Rust panic when
/// the emulator panicked, else the last line that is not a `note:`.
pub fn emulator_error_reason(stderr: &str) -> String {
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

    #[test]
    fn loads_vectors_with_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let elf = dir.path().join("t.elf");
        std::fs::write(&elf, b"").unwrap();

        let isa = IoVectors::load(&elf, false).unwrap();
        assert_eq!(isa, IoVectors { input: None, expected: None, outcome: Outcome::Pass });
        assert!(!isa.has_io());

        let standards = IoVectors::load(&elf, true).unwrap();
        assert_eq!(standards.input.as_deref(), Some(&[][..]));
        assert_eq!(standards.expected.as_deref(), Some(PASS_VERDICT));

        std::fs::write(dir.path().join("t.input"), b"in").unwrap();
        std::fs::write(dir.path().join("t.expected"), b"out").unwrap();
        std::fs::write(dir.path().join("t.outcome"), b"fail\n").unwrap();
        let v = IoVectors::load(&elf, false).unwrap();
        assert_eq!(v.input.as_deref(), Some(&b"in"[..]));
        assert_eq!(v.expected.as_deref(), Some(&b"out"[..]));
        assert_eq!(v.outcome, Outcome::Fail);

        std::fs::write(dir.path().join("t.outcome"), b"maybe").unwrap();
        assert!(IoVectors::load(&elf, false).is_err());
    }
}
