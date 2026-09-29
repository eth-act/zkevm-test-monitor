# eth-act standards tests

These tests check the guest interfaces that the
[EIP-8025 readiness review](https://github.com/jsign/eip-8025/blob/jsign-readiness/READINESS.md#zkvms)
asks of each zkVM. It covers four
[eth-act/zkevm-standards](https://github.com/eth-act/zkevm-standards) items. The standards
repository is pinned by `zkevm_standards_commit` in `config.json`. The guests include
`zkvm_io.h` and `zkvm_accelerators.h` from it. `src/run-eth-act-standards-tests.sh` fetches that
commit into `out/deps/zkevm-standards` and records it with each run.

| Group | Standard | Tests |
|---|---|---|
| `io/` | [I/O interface](https://github.com/eth-act/zkevm-standards/tree/main/standards/io-interface) (`zkvm_io.h`) | input sizes 0, 1, 13 and 64 KiB; `read_input` idempotence; echo; split, byte-wise and zero-length writes; outputs of 257 and 1024 bytes |
| `accelerators/` | [C interface for accelerators](https://github.com/eth-act/zkevm-standards/tree/main/standards/c-interface-accelerators) (`zkvm_accelerators.h`) | one program for each of the 19 functions, with valid and invalid known-answer cases; three programs that pass a NULL pointer and expect a panic |
| `memory/` | [Accelerated memory operations](https://github.com/eth-act/zkevm-standards/tree/main/standards/accelerated-memory-operations) | `memcpy`, `memmove`, `memset` and `memcmp` over all alignments and lengths 0..72, plus link resolution against weak decoys |
| `termination/` | [Standard termination semantics](https://github.com/eth-act/zkevm-standards/tree/main/standards/standard-termination-semantics) | `main` returns 1, and `main` returns 7: each must be an abnormal termination with that error code |

The suite runs execution only. It does not prove.

## How a test works

Each test is a small, standalone C program. It is an ACT4 C test (ACT4 4.1.0 or later), so it
has the ACT4 test header (`START_TEST_CONFIG`) and uses ACT4's C test runtime (`c_test.h`). It
links against the vendor's static library and calls it only through the standard headers.

`build-guests.sh` compiles the programs with ACT4 (`act`) in the zkVM's ACT4 image
(`zkvms/<zkvm>/act4.Dockerfile`). It uses the zkVM's ISA config (`zkvms/<zkvm>/isa-configs/`) with the
`test_config.yaml` and `link.ld` in `zkvms/<zkvm>/standards/`. The linker script puts the vendor's
static library on the link line, so the vendor's `_start` runs `main`. The test ends through the
zkVM's ACT4 halt macros, the same as an ISA test.

The runner judges a test in one of three ways:

- **ACT4 verdict.** A self-checking program calls `rvtest_pass()`, and a failed check calls
  `print_error()` (`include/checks.h`). The runner reads the verdict as for an ISA test:
  the `PASS` marker in the public output on ZisK, the exit code on SP1 and OpenVM. On SP1 and
  OpenVM, a return from `main` also gives exit code 0, so `checks.h` makes `rvtest_pass()`
  first write the public output `PASS`, and the runner requires it. A program that ends
  before `rvtest_pass()` fails.
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
  NULL pointer SHOULD panic. If the call returns, the program prints the status. The
  `termination/` programs return a non-zero value from `main`. The standard says that this is
  an abnormal termination, and that the value is the error code. They expect `fail <code>` and
  do not call `rvtest_pass()`.

The runner puts each execution in one of three classes, as the
[standard termination semantics](https://github.com/eth-act/zkevm-standards/tree/main/standards/standard-termination-semantics)
define them:

| Class | SP1 and OpenVM | ZisK |
|---|---|---|
| Successful termination | the executor exits 0 (the guest halted with exit code 0) | `ziskemu` exits 0 without "finished with error", and a test without `.expected` has no `FAIL` marker |
| Abnormal termination | the executor exits 1: a non-zero guest exit code (with the code), or an execution that the zkVM rejected, such as an invalid memory access (without a code) | the `FAIL` marker, a non-zero `ziskemu` exit, or "finished with error" (always without a code) |
| Host error | any other exit status (2: a usage, I/O, SDK, ELF load or compile error), or a death by signal | `ziskemu` cannot start, writes no output file, or dies by a signal |

A host error is not a guest outcome, so it never passes a test. The executors write the guest's
exit code to a file that the runner names as their fourth argument. ZisK reports no error code,
because ZisK 1.2 and later ignore `a0` at the exit ecall.

`<name>.input` is the private input (default: empty). If a program never finishes, it has no
verdict, so the test fails.

`mem-link-resolution` defines weak `memcpy`, `memmove`, `memset` and `memcmp` functions that give
wrong results. The vendor's strong definitions must replace them at link time.

ZisK has a fixed public output area of 64 u32 words with zero padding. On ZisK, the runner
therefore accepts output that equals the expected bytes followed by zero bytes.

SP1 public values are a variable-length stream, so on SP1 the output must equal the expected
bytes exactly.

OpenVM public values are a fixed area of 256 bytes with zero padding (ere's VM config), so the
runner compares them as for ZisK.

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

## Adding a zkVM

The zkVM must have an ACT4 ISA config (`zkvms/<zkvm>/isa-configs/`) with the `rv64im-zicclsm` UDB
config.

1. Add `zkvms/<zkvm>/standards/`:
   - a `Dockerfile` that builds the vendor library and the host executor;
   - a `test_config.yaml` that names `link.ld` and the ISA config's UDB config;
   - a `link.ld` that includes the vendor library (`INPUT(/vendor/<lib>.a)`) and defines the
     `__stack_*`, `__bss_*` and `__num_harts` symbols that ACT4's C runtime needs.
2. Make the zkVM's backend in `src/runner/src/backends.rs` feed the input to the zkVM and report
   its termination and public output: through the zkVM's own executor (`--binary`, as ziskemu
   does) or an eth-act standards executor (`--io-executor`, as for SP1 and OpenVM).
3. Add the vendor library path, the executor and its runner flag to
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
  EIP-7883 modexp and EIP-4844 KZG vectors. EEST has no JSON vectors for bn254, blake2f and
  ecrecover (only Python test parameters), so those come from go-ethereum only.

The script takes every case of every pinned file that the C interface can express: about 1,780
cases in total. It skips a case whose input is already present, and each case label starts with
its source (`geth` or `eest`). The fixed-size C types cannot express some cases: a wrong input
length, an EIP-2537 field element with nonzero padding, or an ecrecover `v` other than 27 or 28.
The script skips those cases and prints how many it skipped per file. An EEST KZG
input error (`output: null`) is expected to be rejected, like an invalid proof.

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
  return a failure status, or it can return success with `verified == false`.
