use openvm_sdk::{CpuSdk, StdIn};

fn main() {
    let path = std::env::args().nth(1).expect("usage: openvm-binary <elf>");
    let elf = std::fs::read(&path).expect("failed to read ELF");
    let sdk = CpuSdk::riscv32();
    match sdk.execute(elf, StdIn::default()) {
        Ok(_) => std::process::exit(0),
        Err(_) => std::process::exit(1),
    }
}
