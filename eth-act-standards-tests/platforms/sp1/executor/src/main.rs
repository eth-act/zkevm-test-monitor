//! Run one SP1 guest ELF for the eth-act standards tests (execute only, no proving).
//!
//! Usage: sp1-eth-act-standards-executor <elf> <input> <public-values-out>
//!
//! The input file is pushed as ONE stdin chunk, as `SP1Stdin::write_slice`
//! does, because libzkevm's `read_input` returns only the first chunk. The
//! program runs in the same minimal executor that `ProverClient::execute`
//! uses. The raw public-values stream is written to <public-values-out>.
//!
//! Exit status: 0 when the guest halted with exit code 0, 1 when it halted
//! with a non-zero exit code, 2 when the executor failed.

use std::{process::ExitCode, sync::Arc};

use sp1_core_executor::Program;
use sp1_core_executor_runner::MinimalExecutorRunner;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let [_, elf_path, input_path, output_path] = args.as_slice() else {
        eprintln!("usage: sp1-eth-act-standards-executor <elf> <input> <public-values-out>");
        return ExitCode::from(2);
    };
    match run(elf_path, input_path, output_path) {
        Ok(0) => ExitCode::SUCCESS,
        Ok(code) => {
            eprintln!("guest halted with exit code {code}");
            ExitCode::from(1)
        }
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::from(2)
        }
    }
}

fn run(elf_path: &str, input_path: &str, output_path: &str) -> Result<u32, String> {
    let elf = std::fs::read(elf_path).map_err(|e| format!("read {elf_path}: {e}"))?;
    let input = std::fs::read(input_path).map_err(|e| format!("read {input_path}: {e}"))?;
    let program = Program::from(&elf).map_err(|e| format!("load ELF: {e}"))?;

    let mut executor = MinimalExecutorRunner::simple(Arc::new(program));
    executor.with_input(&input);
    while executor.try_execute_chunk().map_err(|e| format!("execution failed: {e}"))?.is_some() {}

    std::fs::write(output_path, executor.public_values_stream())
        .map_err(|e| format!("write {output_path}: {e}"))?;
    Ok(executor.exit_code())
}
