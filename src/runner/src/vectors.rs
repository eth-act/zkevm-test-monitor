//! Per-ELF test vectors and the checks of a guest's public output.
//!
//! Every ELF may have these files next to it:
//! - `<stem>.input`: the private input bytes;
//! - `<stem>.expected`: the expected public output bytes;
//! - `<stem>.outcome`: `pass` (the default), `fail` or `fail <code>`. With
//!   `fail`, the guest must terminate abnormally (a panic, an abort, a non-zero
//!   return from `main`, a failed execution), and with `fail <code>` the zkVM
//!   must also report that error code. A successful termination or a host
//!   error fails the test (see `runner::apply_outcome`).
//!
//! The standards backends default a missing input to empty. Without an
//! expected output, a test is judged by the ACT4 halt verdict, and on SP1 and
//! OpenVM its public output must also be `PASS` (`PASS_OUTPUT`), since their
//! pass halt is exit code 0, like a return from `main`. The ISA backends have
//! no defaults.

use std::path::Path;

use anyhow::{Context, Result, bail};

/// The public output of a passing self-checking standards test.
pub const PASS_OUTPUT: &[u8] = b"PASS";

/// Show at most this many bytes of output in a failure detail.
const DETAIL_BYTES: usize = 48;

/// The expected way for a guest to terminate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Finish normally (and match the expected output, if any).
    Pass,
    /// Terminate abnormally: a panic, an abort, a non-zero return from `main`
    /// or a failed execution. With `code`, the zkVM must report that error code.
    Fail { code: Option<i32> },
}

impl Outcome {
    /// Parse the text of a `.outcome` file: `pass`, `fail` or `fail <code>`.
    pub fn parse(text: &str) -> Option<Self> {
        match text.split_whitespace().collect::<Vec<_>>().as_slice() {
            ["pass"] => Some(Outcome::Pass),
            ["fail"] => Some(Outcome::Fail { code: None }),
            ["fail", code] => code.parse().ok().map(|code| Outcome::Fail { code: Some(code) }),
            _ => None,
        }
    }
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
    /// is empty.
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
            Some(bytes) => {
                let text = String::from_utf8_lossy(&bytes);
                match Outcome::parse(&text) {
                    Some(outcome) => outcome,
                    None => bail!(
                        "unknown outcome '{}' in {}",
                        text.trim(),
                        elf_path.with_extension("outcome").display()
                    ),
                }
            }
        };
        let mut input = read_optional("input")?;
        let expected = read_optional("expected")?;
        if standards {
            input.get_or_insert_with(Vec::new);
        }
        Ok(IoVectors { input, expected, outcome })
    }

    /// Whether the test feeds an input or checks the output.
    pub fn has_io(&self) -> bool {
        self.input.is_some() || self.expected.is_some()
    }
}

/// Compare output from a zkVM whose public output is a fixed-size, zero-padded
/// area (ZisK: 64 u32 slots). The output carries no length, so trailing zero
/// bytes after the expected stream cannot be told apart from padding.
pub fn matches_zero_padded(actual: &[u8], expected: &[u8]) -> bool {
    expected.len() <= actual.len()
        && actual[..expected.len()] == *expected
        && actual[expected.len()..].iter().all(|&b| b == 0)
}

/// Describe an output mismatch.
pub fn describe_mismatch(actual: &[u8], expected: &[u8]) -> String {
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

#[cfg(test)]
mod tests {
    use super::*;

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
    fn describes_mismatch() {
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
        assert_eq!(standards.expected, None);

        std::fs::write(dir.path().join("t.input"), b"in").unwrap();
        std::fs::write(dir.path().join("t.expected"), b"out").unwrap();
        std::fs::write(dir.path().join("t.outcome"), b"fail\n").unwrap();
        let v = IoVectors::load(&elf, false).unwrap();
        assert_eq!(v.input.as_deref(), Some(&b"in"[..]));
        assert_eq!(v.expected.as_deref(), Some(&b"out"[..]));
        assert_eq!(v.outcome, Outcome::Fail { code: None });

        std::fs::write(dir.path().join("t.outcome"), b"fail 7\n").unwrap();
        assert_eq!(IoVectors::load(&elf, false).unwrap().outcome, Outcome::Fail { code: Some(7) });

        std::fs::write(dir.path().join("t.outcome"), b"maybe").unwrap();
        assert!(IoVectors::load(&elf, false).is_err());
    }

    #[test]
    fn parses_outcomes() {
        assert_eq!(Outcome::parse("pass\n"), Some(Outcome::Pass));
        assert_eq!(Outcome::parse("fail"), Some(Outcome::Fail { code: None }));
        assert_eq!(Outcome::parse(" fail  7 \n"), Some(Outcome::Fail { code: Some(7) }));
        assert_eq!(Outcome::parse("fail -1"), Some(Outcome::Fail { code: Some(-1) }));
        assert_eq!(Outcome::parse("fail seven"), None);
        assert_eq!(Outcome::parse("fail 7 8"), None);
        assert_eq!(Outcome::parse("pass 0"), None);
        assert_eq!(Outcome::parse(""), None);
    }
}
