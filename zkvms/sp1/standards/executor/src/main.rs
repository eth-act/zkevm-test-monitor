//! Run one SP1 guest ELF for the eth-act standards tests (execute only, no proving).
//!
//! Usage: sp1-eth-act-standards-executor <elf> <input> <public-values-out> <exit-code-out>
//!
//! The input file is pushed as ONE stdin chunk, as `SP1Stdin::write_slice`
//! does, because libzkevm's `read_input` returns only the first chunk. The
//! program runs in the same minimal executor that `ProverClient::execute`
//! uses. The raw public-values stream is written to <public-values-out>.
//!
//! Exit status: 0 when the guest halted with exit code 0, 1 when the guest
//! terminated abnormally (a non-zero exit code, or an execution that SP1
//! rejected), 2 on a usage, I/O or executor error. When the guest's exit code
//! is known, it is written (decimal) to <exit-code-out>.

use std::{process::ExitCode, sync::Arc};

use sp1_core_executor::{ExecutionError, Program};
use sp1_core_executor_runner::MinimalExecutorRunner;

/// Why the guest did not halt with exit code 0.
enum Error {
    /// The guest halted with a non-zero exit code.
    Halted(u32),
    /// SP1 rejected the guest's execution; the exit code is unknown.
    Rejected(ExecutionError),
    /// A usage, I/O or executor error.
    Host(String),
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let [_, elf_path, input_path, output_path, code_path] = args.as_slice() else {
        eprintln!(
            "usage: sp1-eth-act-standards-executor <elf> <input> <public-values-out> <exit-code-out>"
        );
        return ExitCode::from(2);
    };
    let result = run(elf_path, input_path, output_path);
    let code = match &result {
        Ok(()) => Some(0),
        Err(Error::Halted(code)) => Some(*code),
        Err(_) => None,
    };
    if let Some(code) = code {
        if let Err(e) = std::fs::write(code_path, code.to_string()) {
            eprintln!("error: write {code_path}: {e}");
            return ExitCode::from(2);
        }
    }
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(Error::Halted(code)) => {
            eprintln!("guest halted with exit code {code}");
            ExitCode::from(1)
        }
        Err(Error::Rejected(e)) => {
            eprintln!("execution failed: {e}");
            ExitCode::from(1)
        }
        Err(Error::Host(e)) => {
            eprintln!("error: {e}");
            ExitCode::from(2)
        }
    }
}

fn run(elf_path: &str, input_path: &str, output_path: &str) -> Result<(), Error> {
    let elf = std::fs::read(elf_path).map_err(|e| Error::Host(format!("read {elf_path}: {e}")))?;
    let input =
        std::fs::read(input_path).map_err(|e| Error::Host(format!("read {input_path}: {e}")))?;
    let program = Program::from(&elf).map_err(|e| Error::Host(format!("load ELF: {e}")))?;

    let mut executor = MinimalExecutorRunner::simple(Arc::new(program));
    executor.with_input(&input);
    loop {
        match executor.try_execute_chunk() {
            Ok(Some(_)) => {}
            Ok(None) => break,
            Err(ExecutionError::UnexpectedExitCode(code)) => return Err(Error::Halted(code)),
            Err(e) if is_guest_error(&e) => return Err(Error::Rejected(e)),
            Err(e) => return Err(Error::Host(format!("execution failed: {e}"))),
        }
    }

    std::fs::write(output_path, executor.public_values_stream())
        .map_err(|e| Error::Host(format!("write {output_path}: {e}")))?;
    match executor.exit_code() {
        0 => Ok(()),
        code => Err(Error::Halted(code)),
    }
}

/// Whether the guest caused the error (SP1 rejected its execution), as
/// opposed to the executor or the host.
fn is_guest_error(e: &ExecutionError) -> bool {
    match e {
        ExecutionError::InvalidMemoryAccess(..)
        | ExecutionError::InvalidMemoryAccessUntrustedProgram(_)
        | ExecutionError::UnsupportedSyscall(_)
        | ExecutionError::Breakpoint()
        | ExecutionError::ExceededCycleLimit(_)
        | ExecutionError::InvalidSyscallUsage(_)
        | ExecutionError::Unimplemented()
        | ExecutionError::EndInUnconstrained()
        | ExecutionError::UnconstrainedCycleLimitExceeded(_)
        | ExecutionError::UnexpectedExitCode(_)
        | ExecutionError::InstructionNotFound()
        | ExecutionError::UnhandledTrap(_)
        | ExecutionError::TooMuchMemory() => true,
        // The executor's state, its child process or its memory monitor.
        ExecutionError::InvalidShardingState()
        | ExecutionError::KilledByMemoryMonitor(_)
        | ExecutionError::ChildKilled()
        | ExecutionError::Other(_) => false,
    }
}
