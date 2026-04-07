use std::path::Path;
use std::process::Command;
use std::sync::OnceLock;

use anyhow::{bail, Context, Result};

/// Detect objcopy binary once.
///
/// Tries in order: riscv64-unknown-elf-objcopy, llvm-objcopy, then searches
/// rustup toolchains for llvm-objcopy (installed via `rustup component add llvm-tools`).
fn objcopy_binary() -> &'static str {
    static OBJCOPY: OnceLock<String> = OnceLock::new();
    OBJCOPY.get_or_init(|| {
        // Preferred: RISC-V cross-toolchain or system llvm-objcopy
        for name in ["riscv64-unknown-elf-objcopy", "llvm-objcopy"] {
            if Command::new(name).arg("--version").output().is_ok() {
                return name.to_owned();
            }
        }

        // Search rustup toolchains for llvm-objcopy
        if let Ok(home) = std::env::var("HOME") {
            let rustup_base = format!("{home}/.rustup/toolchains");
            if let Ok(entries) = std::fs::read_dir(&rustup_base) {
                for entry in entries.flatten() {
                    let candidate = entry.path()
                        .join("lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-objcopy");
                    if candidate.exists() {
                        return candidate.to_string_lossy().into_owned();
                    }
                }
            }
        }

        // Last resort: system objcopy (won't work for RISC-V ELFs on x86)
        "objcopy".to_owned()
    })
}

/// Convert an ELF file to a flat binary using objcopy (all sections).
pub fn elf_to_flat_binary(elf_path: &Path, out_path: &Path) -> Result<()> {
    run_objcopy(elf_path, out_path, &[])
}

/// Extract ROM sections (code + data) from an ELF for `airbender-cli prove`.
///
/// The linker script places code and .data within the first 2MB (ROM range).
/// Writable-only sections (.exit_data, .bss) are placed at 0x200000+ (RAM)
/// and excluded here to keep the binary under 2MB.
pub fn elf_to_rom_binary(elf_path: &Path, out_path: &Path) -> Result<()> {
    run_objcopy(elf_path, out_path, &[
        "--only-section=.text.init",
        "--only-section=.text",
        "--only-section=.exit_seq",
        "--only-section=.data",
        "--only-section=.data.string",
    ])
}

fn run_objcopy(elf_path: &Path, out_path: &Path, extra_args: &[&str]) -> Result<()> {
    let objcopy = objcopy_binary();

    let output = Command::new(objcopy)
        .args(["-O", "binary"])
        .args(extra_args)
        .arg(elf_path)
        .arg(out_path)
        .output()
        .with_context(|| format!("failed to run {objcopy}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!(
            "{objcopy} failed (exit {}): {}",
            output.status.code().unwrap_or(-1),
            stderr.trim()
        );
    }

    Ok(())
}
