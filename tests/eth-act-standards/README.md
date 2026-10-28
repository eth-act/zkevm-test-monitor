# eth-act standards tests

These tests check the guest interfaces that the
[EIP-8025 readiness review](https://github.com/jsign/eip-8025/blob/jsign-readiness/READINESS.md#zkvms)
asks of each zkVM. It covers five
[eth-act/zkevm-standards](https://github.com/eth-act/zkevm-standards) items. The standards
repository is pinned by `zkevm_standards_commit` in `config.json`. The guests include
`zkvm_io.h` and `zkvm_accelerators.h` from it. `src/run-eth-act-standards-tests.sh` fetches that
commit into `out/deps/zkevm-standards` and records it with each run.

| Group | Standard | Tests |
|---|---|---|
| `io/` | [I/O interface](https://github.com/eth-act/zkevm-standards/tree/main/standards/io-interface) (`zkvm_io.h`) | input sizes 0, 1, 13 and 64 KiB; `read_input` idempotence (bytes checked after every call, and repeated calls for the empty and 64 KiB inputs); no side effects of `read_input` (canaries around its out-parameters and in `.data` and `.bss`, and the input unchanged after the guest fills `.bss` and the stack); echo; a first `read_input` after output writes and stack use; split, byte-wise and zero-length writes, including `write_output(NULL, 0)`; a buffer changed between writes; writes from `.rodata`, `.data` and `.bss`; an output that ends in zero bytes, and an empty output; outputs of 257 bytes (in one call and in 64-byte pieces) and 1024 bytes |
| `accelerators/` | [C interface for accelerators](https://github.com/eth-act/zkevm-standards/tree/main/standards/c-interface-accelerators) (`zkvm_accelerators.h`) | one program for each of the 19 functions, with valid and invalid known-answer cases (the byte-buffer functions `keccak256`, `sha256`, `ripemd160` and `modexp` also with each buffer at a misaligned address); three programs that pass a NULL pointer and expect a panic |
| `memory/` | [Accelerated memory operations](https://github.com/eth-act/zkevm-standards/tree/main/standards/accelerated-memory-operations) | `memcpy`, `memmove`, `memset` and `memcmp`: Arm's optimized-routines tests (`mem-aor-*`: alignments 0..31, lengths 0..99 and doubling to 800), and our tests for what they miss (`mem-*`: alignments 0..7, lengths 0..72, bytes of 0x80 and more, guard bytes, unchanged inputs); plus link resolution (`mem-link-*`) |
| `elf/` | [ELF loading and validation](https://github.com/eth-act/zkevm-standards/tree/main/standards/elf-loading-and-validation) | the initial memory image (`.data`, `.bss`, `.rodata`); loads from the executable segment; calls to code in `.data` and to code that the guest wrote; a store over code; crafted ELFs that the loader must accept (ignored section headers and `PT_NOTE`, `p_paddr`, zero fill after 17 to 23 file bytes) or reject (one for each header, segment and entry point check); for a `PF_X` zkVM, two static checks of the linked guests (see ELF loading) |

By default the suite runs through ere, with execute, prove and verify (`ACT4_MODE`, default
`full`). Every stage must give the expected public output. A test that expects an abnormal
termination or a rejection (`.outcome`) has no valid proof, so it is only executed, and the
dashboard counts proving and verification over the other tests (see ELF loading for the prover
check of a rejected ELF). `BACKEND=noere` runs the suite without ere, on
the host executors and provers below; there `ACT4_MODE` defaults to `execute` (see Running).
`TESTS` runs only some tests (see Selecting tests).

## How a test works

Each test is a small, standalone C program. It is an ACT4 C test (ACT4 4.1.0 or later), so it
has the ACT4 test header (`START_TEST_CONFIG`) and uses ACT4's C test runtime (`c_test.h`). It
links against the vendor's static library and calls it only through the standard headers.

`build-guests.sh` compiles the programs with ACT4 (`act`) in the zkVM's ACT4 image
(`zkvms/<zkvm>/act4.Dockerfile`). It uses the zkVM's ISA config (`zkvms/<zkvm>/isa-configs/`) with the
`test_config.yaml` in `zkvms/<zkvm>/standards/`, and links the vendor's static library, so the
vendor's `_start` runs `main`. The test ends through the zkVM's ACT4 halt macros, the same as an
ISA test.

The linker script is the zkVM's own, from its repository at the pinned commit, with only the changes
in `zkvms/<zkvm>/standards/link.ld.patch`. Each change in the patch is a deviation of the vendor's
script, with a comment that gives its reason (#58):

- ZisK (`ziskbuild/zisk_linker_script.ld`): `.bss` shares the data segment, because with GNU ld a
  guest without initialized data gets an empty segment at address 0, which `ziskemu` rejects.
- SP1 (`zkevm/zkvm.ld`): `PHDRS`, because without them GNU ld emits a writable and executable
  segment, which SP1's loader rejects; and a NOP fill, because SP1's loader rejects a word in an
  executable segment that does not decode (the ELF loading standard allows such words).
- OpenVM publishes no linker script: its guest build uses the linker's default layout with
  `-Ttext=0x00200800`. The OpenVM guests link the same way (`zkvms/openvm/standards/link-args`, plus
  `-z separate-code`, which LLD does by default). ACT requires a linker script, so
  `zkvms/openvm/standards/link.ld` is an empty placeholder (`INSERT`, so GNU ld's default script
  stays).

ACT's C start code references `__bss_start`, `__bss_end`, `__stack_top`, `__stack_size` and
`__num_harts`. It is linked but never runs, so `build-guests.sh` defines them on the link line
(`--defsym`), not in the linker scripts. Building without ACT would remove them (#57).

The runner judges a test in one of five ways:

- **ACT4 verdict.** A self-checking program calls `rvtest_pass()`, and a failed check calls
  `print_error()` (`include/checks.h`). The runner reads the verdict as for an ISA test:
  the halt macros write `PASS` or `FAIL` to public output 0 on every zkVM, and SP1 and OpenVM
  also exit with the verdict. On SP1 and OpenVM, a return from `main` also gives exit code 0,
  so the runner also requires the `PASS` output. A program that ends before `rvtest_pass()`
  fails.
- **Expected output.** An I/O write program returns from `main`. Its public output must equal
  `<name>.expected`. `io/write_io_vectors.py` writes the input and the expected output. It
  fails the build if an I/O test has no entry, or if a program that writes output has no
  expected output.
- **Expected abnormal termination.** `<name>.outcome` holds `fail` or `fail <code>`. The
  program must terminate abnormally, and with `fail <code>` the zkVM must also report that
  error code. The runner gives these verdicts:
  - an abnormal termination with the expected code, or with any code for `fail`, passes;
  - an abnormal termination with another code fails with `wrong error code`;
  - for `fail <code>`, an abnormal termination without a code fails with `error code not reported`;
  - a normal finish fails with `did not panic` (for `fail`) or `did not terminate abnormally`
    (for `fail <code>`);
  - a host error fails.

  The `accel-null-*` programs expect `fail`: the standard says that a function called with a
  NULL pointer SHOULD panic. If the call returns, the program prints the status.
- **Expected rejection.** `<name>.outcome` holds `reject`. The zkVM must reject the ELF before
  the guest runs (a rejected ELF, below). A guest that runs fails the test with `not rejected`,
  and a host error fails it. See ELF loading for the prover check.
- **Pass or abnormal termination.** `<name>.outcome` holds `pass-or-fail`. The program passes
  as for an ACT4 verdict, or it terminates abnormally.

The runner puts each execution in one of three classes, as the
[standard termination semantics](https://github.com/eth-act/zkevm-standards/tree/main/standards/standard-termination-semantics)
define them, or reports a rejected ELF (ELF loading standard):

| Class | SP1 and OpenVM | ZisK |
|---|---|---|
| Successful termination | the executor exits 0 (the guest halted with exit code 0) | `ziskemu` exits 0 without "finished with error", and a test without `.expected` has no `FAIL` marker |
| Abnormal termination | the executor exits 1: a non-zero guest exit code (with the code), or an execution that the zkVM rejected, such as an invalid memory access (without a code) | the `FAIL` marker, or a guest fault on stderr: an invalid memory address, a load from an address without readable data, a jump outside the program, or "finished with error" (always without a code) |
| Rejected ELF | the executor exits 3: the zkVM's loader returned an error | `ziskemu` exits 1 with `Error during emulation: Unknown(...)`, its error for an ELF that it cannot convert, unless it could not read the file |
| Host error | any other exit status (2: a usage, I/O, SDK or compile error; 101: a panic), or a death by signal | any other non-zero `ziskemu` exit (for example an ELF file that it cannot read, or a shared library loader error), no output file, or a death by signal |

A rejected ELF is not a guest outcome: only a `reject` test passes on it. A host error is not a
guest outcome either, so it never passes a test. The runner exits 3 when a test
hit a host error and 2 when it finds no ELFs; the run script then records no history. The executors write the guest's
exit code to a file that the runner names as their fourth argument. ZisK reports no error code,
because ZisK 1.2 and later ignore `a0` at the exit ecall.

`<name>.input` is the private input (default: empty). If a program never finishes, it has no
verdict, so the test fails.

The `mem-aor-*` guests run Arm's optimized-routines tests, vendored in
`memory/optimized-routines/` (see its `README.md` for the source commit and the one change).

`mem-link-<fn>` checks the standard's linking rule: when the vendor library has a strong `<fn>`, it
must take effect regardless of how the guest is built. The guest defines weak `memcpy`, `memmove`,
`memset` and `memcmp`, as a Rust or C runtime does (for Rust, compiler-builtins). Its `<fn>` is
deliberately wrong, and the other three are correct (`memory/mem_link.h`). The guest object comes
before the library in the link, so the wrong `<fn>` wins unless the library puts its `<fn>` in an
object that every guest links (such as the one with `_start`) or requires `--whole-archive`. Our
link does not use `--whole-archive`, so a library that relies on it fails. `build-guests.sh`:

- builds `mem-link-<fn>` as a stub that passes when the library has no strong `<fn>`: acceleration is
  optional, so a function that is not accelerated has no linking rule to check;
- stops if a `mem-link-<fn>` ELF resolves `<fn>` to anything other than the library's strong `<fn>`
  or the guest's `decoy_<fn>`, because another weak `<fn>` (such as compiler-builtins') would let
  the test pass.

The ELF check treats any strong `<fn>` as the library's. That holds because nothing else on our link
line defines a strong `<fn>`: ACT links no C library. In a link that has another strong `<fn>` (for
example from a libc), the linker loads only the first archive member that defines it, without an
error, so a strong symbol alone does not show its source. `-Wl,--trace-symbol=<fn>` (or a map file,
`-Wl,-Map=<file>`) shows which input defined it.

The test does not check the standard's documentation or LTO clauses.

ZisK has a fixed public output area of 64 u32 words with zero padding. On ZisK, the runner
therefore accepts output that equals the expected bytes followed by zero bytes.

SP1 public values are a variable-length stream, so on SP1 the output must equal the expected
bytes exactly.

OpenVM public values are a fixed area of 256 bytes with zero padding (ere's VM config), so the
runner compares them as for ZisK.

On ZisK and OpenVM, an output that ends in zero bytes therefore matches the same output without
them. There, `io-write-trailing-zeros` cannot tell whether the zkVM kept the final zero bytes, and
`io-write-nothing` checks only that the zkVM wrote no nonzero byte.

## ELF loading

The `elf/` tests check the
[ELF loading and validation standard](https://github.com/eth-act/zkevm-standards/tree/main/standards/elf-loading-and-validation).
`zkvms/<zkvm>/standards/elf.env` sets the zkVM's parameters:

- `ELF_EXEC_PERM`: the flags of an executable segment that the zkVM accepts, `x` (`PF_X` alone,
  execute-only) or `rx` (`PF_X | PF_R`). ZisK declares `x`: its linker script puts `.text` in a
  `PF_X` segment. SP1 declares `rx`: its loader requires `PF_R` on every segment. OpenVM declares
  `rx`: its loader puts the words of the executable segment in the memory image too.
- `ELF_OUTSIDE_ADDR`: an address outside the zkVM's addressable space (default
  `0x4000000000000000`).
- `ELF_BOOT_ADDR`: the fixed address where the zkVM begins execution, for a zkVM that does not
  start at `e_entry` (default: none, as for the three zkVMs here).

The guests compare memory with values that their code computes:

| Test | What it does | Outcome |
|---|---|---|
| `elf-image` | checks that `.data` holds its file bytes, `.bss` holds zero and `.rodata` is readable | pass |
| `elf-tail` | the base of the `accept-tail-<r>` variants; without an input, it only passes | pass |
| `elf-text-read` | loads an instruction word and compares it with the encoding | pass on `rx`, `fail` on `x` |
| `elf-text-data` | loads a word that is not an instruction from the executable segment (`rx` only) | pass |
| `elf-exec-data` | calls code in `.data` | `fail` |
| `elf-exec-written` | writes code to `.bss` and calls it | `fail` |
| `elf-text-patch` | stores an instruction over a function and calls it: the old code must run and, on `rx`, a load must give the old word; or the program terminates abnormally | `pass-or-fail` |

A check that fails in `elf-text-read` and `elf-text-patch` returns from `main` without the `PASS`
verdict, because an abnormal termination would pass these tests.

`elf/mutate_elf.py` writes crafted variants of `elf-image` (and of `elf-tail`):

- `accept-*` (the guest must pass): `accept-extra-phdr` (a `PT_NOTE` whose `p_vaddr` is the
  checked `.data` bytes), `accept-no-shdrs`, `accept-shdrs-altered` (changed address, size,
  type and flags of each allocated section, and an invalid `.symtab` link), `accept-paddr`
  (`p_paddr` differs from `p_vaddr`), and `accept-tail-1` to `accept-tail-7` (a read-only
  segment with 16 + r file bytes and 16 bytes of zero fill; the input gives its address and r).
- `reject-*` (outcome `reject`), each with one broken rule: `reject-magic`, `reject-class32`
  (an rv32 program from `elf/rv32/`, which `build-guests.sh` links at the zkVM's entry
  address), `reject-msb`, `reject-machine`, `reject-type`, `reject-vaddr-misaligned` (the
  executable segment at 2 mod 4), `reject-overlap`, `reject-vaddr-outside` (a segment at
  `ELF_OUTSIDE_ADDR`), `reject-wx`, `reject-exec-perm` (the other flags combination),
  `reject-entry-misaligned`, `reject-entry-outside`, `reject-entry-not-exec`, and, with
  `ELF_BOOT_ADDR`, `reject-entry-not-boot`.

SP1's and OpenVM's executors exit 3 when the zkVM's loader returns an error, and the ZisK backend
reads `ziskemu`'s error line (see the classes above). Through ere, a zkVM error from ere's `setup`
is a rejected ELF. ere's server exits when it starts with an ELF that its zkVM rejects, so a new
server starts with `elf/elf-image.elf`, and `setup` then switches it to the test's ELF. The runner
checks no diagnostic text.

An invalid ELF must not reach the prover. ere rejects it at `setup`, before any proof. On the noere
path, `ACT4_MODE=prove` or `full` also gives each ELF that the zkVM rejected to the zkVM's prover.
The test passes only if the prover makes no proof and writes no proof file (`refused`).

For `ELF_EXEC_PERM=x`, `build-guests.sh` runs `elf/static_checks.py` on every guest that the
zkVM's linker script linked (not on the crafted variants) and writes `elf/elf-static.json`:

- `elf-static-segments`: every allocated section with `SHF_EXECINSTR` lies in an executable
  segment, and no other allocated section does;
- `elf-static-decode`: the whole content of each executable segment decodes as RISC-V
  instructions (`objdump -M max`). A zero halfword, which the ISA defines as illegal, does not.

The run script adds both checks to the results as tests of the `elf` group, except with `TESTS`.
They have no proof, so the dashboard counts proving without them.

The tests do not check `e_flags`, the order of the program headers, the proof's commitment,
diagnostic text, or what the standard permits but does not require (for example, rejecting data
in an execute-only segment).

## Platforms

| zkVM | Vendor library | Host |
|---|---|---|
| ZisK | `ziskos-staticlib` + ZisK's own linker script at tag v1.3.0-alpha, the version eth-act/ere pins | `ziskemu` at the same tag (`out/bin/zisk-eth-act-standards-emu`) |
| SP1 | zkEVM SDK `libzkevm.a` + `zkvm.ld` (`make sdk` in `zkevm/`) at upstream tag v6.6.0, the version eth-act/ere pins | `sp1-eth-act-standards-executor` (`zkvms/sp1/standards/executor`) |
| OpenVM | none from OpenVM; eth-act/ere's `ere-platform-openvm` at a fixed ere commit, over OpenVM tag v2.1.0-preview | `openvm-eth-act-standards-executor` (`zkvms/openvm/standards/executor`) |

The ZisK image pins its own ZisK tag, not the monitor's ZisK pin for the ACT4 suites. It
builds `ziskemu` (execute only) at that tag and copies it and its shared libraries to
`out/bin/`.

The SDK is not in the monitor's SP1 fork (v6.1.0), so the SP1 image pins its own SP1 tag.
`sp1-eth-act-standards-executor` is built in the same image and copied to `out/bin/`. It runs the guest in
SP1's minimal executor at that tag and passes the input as one stdin chunk, because
`read_input` returns only the first chunk.

OpenVM ships no C library for guests. Its own C-interface PRs
([#3075](https://github.com/openvm-org/openvm/pull/3075) to #3080) were closed unmerged. The
OpenVM results therefore test eth-act/ere's C layer on OpenVM's guest libraries, not an OpenVM
deliverable, and each history run says so in `notes`. `zkvms/openvm/standards/vendor` builds
`ere-platform-openvm` as a static library, the way ere compiles OpenVM guests with a stock
nightly toolchain. Everything in it comes from ere and OpenVM (`_start`, allocator, panic
handler, the `zkvm_*` accelerators, and `openvm-mem` for `memcpy` and friends), except for
`read_input` and `write_output`. These two functions forward to ere's `OpenVMPlatform`:

- `read_input` reads the input once and returns the same buffer on each call.
- `write_output` appends to a buffer and reveals the whole buffer again, because ere reveals
  from byte 0 on each call. ere limits the output to 256 bytes.

The OpenVM linker script puts the program at `0x00200800`, where OpenVM guests start.
`openvm-eth-act-standards-executor` runs the guest in OpenVM's SDK executor, with the VM config that ere's
prover uses and the input as one input vector.

## Running

```bash
./run eth-act-standards-tests zisk      # only these tests
./run eth-act-standards-tests sp1 openvm
./run eth-act-standards-tests           # every zkVM with a platform
./run tests zisk                        # ISA tests, then these tests
```

The results go to `out/<zkvm>/results-eth-act-standards.json` and
`results/history/<zkvm>-eth-act-standards.json`. The dashboard shows one column per group.

### Without ere

`BACKEND=noere` builds each zkVM's executor in this repository's containers, so it can test any
commit or fork. `ACT4_MODE=prove` or `full` proves (and in `full` verifies) every test that passes
execution, on an NVIDIA GPU:

- OpenVM: the standards executor proves and verifies, built with OpenVM's GPU prover. `verify`
  also checks that the proof is of the test's ELF (its app exe commit) and proves the execution's
  public output, so a valid proof of another program or output fails.
- SP1 and ZisK: `sp1-prover` and `cargo-zisk-cuda` from `./run build <zkvm>` (`GPU=1` for ZisK).
  The script refuses a prover built from another commit than the standards image. SP1's GPU
  server needs a CUDA 12 runtime (`libcudart.so.12`); the script finds one or stops (set
  `SP1_CUDA_LIB=<dir>` to choose it).

`OPENVM_EXECUTOR_GIT` and `OPENVM_EXECUTOR_REV` build the OpenVM executor, and so its prover, from
another OpenVM commit. The guest library keeps ere's pin, and the run's notes say that the
executor is not the pinned OpenVM.

```bash
BACKEND=noere ACT4_MODE=full ./run eth-act-standards-tests openvm
OPENVM_EXECUTOR_GIT=https://github.com/<owner>/openvm OPENVM_EXECUTOR_REV=<commit> \
  BACKEND=noere ACT4_MODE=full ./run eth-act-standards-tests openvm
```

### Selecting tests

On both paths, `TESTS` runs only some tests and records no history. It holds words separated by
spaces or commas. A word that is a test name (`io-echo`) or a group (`io`, `accelerators`,
`memory`, `elf`) selects exactly that. Any other word is a glob (`io-write-*`) or a substring (`bls`) of
the test names. A word that selects no test stops the run.

```bash
TESTS=io-echo BACKEND=noere ACT4_MODE=full ./run eth-act-standards-tests openvm
TESTS="io bls" ./run eth-act-standards-tests zisk
```

## Adding a zkVM

The zkVM must have an ACT4 ISA config (`zkvms/<zkvm>/isa-configs/`) with the `rv64im-zicclsm` UDB
config.

1. Add `zkvms/<zkvm>/standards/`:
   - a `Dockerfile` that builds the vendor library and the host executor;
   - a `test_config.yaml` that names `link.ld` and the ISA config's UDB config;
   - a `link.ld.patch` with the changes the zkVM's own linker script needs (or, if the zkVM
     publishes none, a `link-args` file with its link options and a placeholder `link.ld`);
   - an `elf.env` with the zkVM's ELF loading parameters (see ELF loading).
2. Make the zkVM's backend in `src/runner/src/zkvm_backends.rs` feed the input to the zkVM and
   report its termination and public output: through the zkVM's own executor (`--binary`, as
   ziskemu does) or an eth-act standards executor (`--io-executor`, as for SP1 and OpenVM).
3. Add the vendor library path, the linker script path (`VENDOR_LD`), the executor and its runner
   flag to
   `src/run-eth-act-standards-tests.sh`.

## Accelerator vectors

The accelerator tests include `accelerators/vectors/<function>.h`. These headers are not checked
in: `build-guests.sh` generates them for every guest build, in the ACT4 image (about 1 s, or 10 s
with an empty download cache in `out/deps/accel-vectors`). To look at them locally, run:

```bash
uv run --no-project --with pycryptodome --with ecdsa tests/eth-act-standards/tools/gen_accel_vectors.py
```

The script lists the sources for every case. Most cases come from two sets of precompile test
data, converted to the C interface:

- go-ethereum `core/vm/testdata/precompiles` at tag v1.17.6, for every precompile;
- ethereum/execution-specs (EEST) `tests/` at tag `tests@v20.0.2`, for the EIP-2537 BLS12-381,
  EIP-7883 modexp and EIP-4844 KZG vectors;
- the EEST pytest cases at the same tag, for ecrecover, ripemd160, bn254, blake2f, modexp, point
  evaluation, BLS12-381 and P-256. EEST keeps most precompile cases as pytest parameters, not
  as JSON files. `tools/extract_eest_cases.py` imports the EEST test modules and writes their
  cases to `tools/eest_pytest_vectors.json`. That file is checked in, because importing EEST
  needs its whole Python workspace. To regenerate it after a change of the EEST pin, run
  `uv run python <this dir>/tools/extract_eest_cases.py` in an execution-specs checkout at the
  pinned commit.

The script takes every case of every pinned file that the C interface can express: about 2,530
cases in total. It skips a case whose input is already present, and each case label starts with
its source (`geth` or `eest`). The fixed-size C types cannot express some cases: a wrong input
length, an EIP-2537 field element with nonzero padding, or an ecrecover `v` other than 27 or 28.
The script skips those cases and prints how many it skipped per file. It also skips EEST cases
that fail only because of an EVM rule: a point evaluation versioned hash that does not match
the commitment, a modexp input above the EIP-7823 size limit, and a valid blake2f input that
runs out of gas. An EEST KZG input error (`output: null`) is expected to be rejected, like an
invalid proof.

`tools/accel_vector_sources.json` pins these files: the commit of each source and the sha256 of
each file. The script downloads each file at that commit, checks the sha256, and stops on a
mismatch. It caches the files in `~/.cache/eth-act-standards-vectors`, or in the `--cache` directory.

Where the C interface does not define a behavior, the
tests follow the EVM precompile:

- EIP-2537 field elements are 48 bytes, without the 16 zero bytes of padding.
- BN254 G2 coordinates use the EVM order (imaginary part first).
- A zero `modexp` modulus gives an all-zero result.
- A `blake2f` final flag other than 0 or 1 must return a failure status.
- A signature, pairing or KZG check that is invalid may fail in either of two ways: it can
  return a failure status, or it can return success with `verified == false`. The test sets the
  flag to the opposite of the expected result before each call, so a function that returns success
  without writing the flag fails.
