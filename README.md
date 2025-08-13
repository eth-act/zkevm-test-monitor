# RISCOF for ZKVMs

The [RISC-V Architectural Tests](https://github.com/riscv-non-isa/riscv-arch-test) are used by RISC-V International to determine whether a RISC-V implementation is officially compatible with the specification (see [here](https://riscv.org/about/brand-guidelines/)). The framework of the tests is differential. A test vector is an assembly file (.S file) that must be compiled to an ELF file for both a reference model ("REF") and the device under testing ("DUT").  Both REF and DUT must not only be able to execute the RISC-V file, but also they must have additional functionality to extract and write out a region of memory consisting of "signatures", which checkpoints written during execution. If all signatures match, the DUT passes the test suite.

This repository provides a Docker container for running these tests using the canonical Python framework [RISCOF](https://github.com/riscv-software-src/riscof/) against the formally specified [Sail reference model](https://github.com/riscv/sail-riscv). Applying the test suite to a given RISC-V emulator means:
1) Adding signature extraction functionality to the emulator; 
2) Developing a plugin for that emulator.

A plugin specifies the particular ISA implemented by the emulator (register size and supported extensions), it describes how to compile the test vectors for the emulator, and it implements certain C preprocessor macros used in the test vectors.Examples of plugins can be found in [plugins](./plugins). 

With these features in hand, we can run the tests with the given emulator as the DUT. For this we build the container with
```
docker build -t riscof:latest .
```
(or pull it from ...) and run it with the emulator binary directory, plugin directory, and work directory mounted:
```
docker run --rm \
    -v "$PWD/plugins/<emulator-name>:/dut/plugin" \
    -v "<path to directory containing emulator binary>:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest
```

The results directory will contain all test results including:
- `report.html` - The test report summary showing pass/fail results
- Test binaries, logs, and signature files
