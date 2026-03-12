use std::path::{Path, PathBuf};

use rayon::prelude::*;

use crate::backends::{Backend, Mode, RunResult};

/// Discover all ELF files in `elf_dir` recursively, run each through the backend
/// in parallel, and return results in deterministic (alphabetical) order.
pub fn run_tests(backend: &Backend, elf_dir: &Path, jobs: usize, mode: Mode) -> Vec<(PathBuf, RunResult)> {
    let mut elfs = discover_elfs(elf_dir);
    elfs.sort();

    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(jobs)
        .build()
        .expect("failed to build rayon thread pool");

    pool.install(|| {
        elfs.par_iter()
            .map(|elf_path| {
                let result = backend.run_elf(elf_path, mode);
                (elf_path.clone(), result)
            })
            .collect()
    })
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
/// memory. Other backends default to the number of available CPU cores.
pub fn default_jobs(zkvm: &str) -> usize {
    match zkvm {
        "airbender-prove" => 1, // GPU: one prove at a time
        "zisk-prove" | "zisk" => {
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
