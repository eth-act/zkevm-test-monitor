use openvm_sdk::{config::AggregationSystemParams, Sdk, StdIn};
use openvm_stark_sdk::config::{app_params_with_100_bits_security, MAX_APP_LOG_STACKED_HEIGHT};

fn main() {
    let path = std::env::args().nth(1).expect("usage: openvm-binary <elf>");
    let elf = std::fs::read(&path).expect("failed to read ELF");
    let app_params = app_params_with_100_bits_security(MAX_APP_LOG_STACKED_HEIGHT);
    let agg_params = AggregationSystemParams::default();
    let sdk = Sdk::riscv64(app_params, agg_params);
    match sdk.execute(elf, StdIn::default()) {
        Ok(_) => std::process::exit(0),
        Err(e) => {
            eprintln!("execute failed: {e}");
            std::process::exit(1);
        }
    }
}
