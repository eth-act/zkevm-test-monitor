# eth-act standards tests

These tests check the guest interfaces that the
[EIP-8025 readiness review](https://github.com/jsign/eip-8025/blob/jsign-readiness/READINESS.md#zkvms)
asks of each zkVM. It covers three
[eth-act/zkevm-standards](https://github.com/eth-act/zkevm-standards) items. The standards
repository is pinned by `zkevm_standards_commit` in `config.json`. The guests include
`zkvm_io.h` and `zkvm_accelerators.h` from it. `src/run-eth-act-standards-tests.sh` fetches that
commit into `out/deps/zkevm-standards` and records it with each run.

| Group | Standard | Tests |
|---|---|---|
| `io/` | [I/O interface](https://github.com/eth-act/zkevm-standards/tree/main/standards/io-interface) (`zkvm_io.h`) | input sizes 0, 1, 13 and 64 KiB; `read_input` idempotence; echo; split, byte-wise and zero-length writes; outputs of 257 and 1024 bytes |
| `accelerators/` | [C interface for accelerators](https://github.com/eth-act/zkevm-standards/tree/main/standards/c-interface-accelerators) (`zkvm_accelerators.h`) | one program for each of the 19 functions, with valid and invalid known-answer cases; three programs that pass a NULL pointer and expect a panic |
| `memory/` | [Accelerated memory operations](https://github.com/eth-act/zkevm-standards/tree/main/standards/accelerated-memory-operations) | `memcpy`, `memmove`, `memset` and `memcmp` over all alignments and lengths 0..72, plus link resolution against weak decoys |

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
  the `PASS` marker in the public output on ZisK, the exit code on SP1 and OpenVM.
- **Expected output.** An I/O write program returns from `main`. Its public output must equal
  `<name>.expected`. `io/write_io_vectors.py` writes the input and the expected output.
- **Expected panic.** `<name>.outcome` holds `fail`. The program must terminate abnormally (a
  panic or a failed execution), and a normal finish fails the test with the detail
  `did not panic`. The `accel-null-*` programs use this: the standard says that a function
  called with a NULL pointer SHOULD panic. If the call returns, the program prints the status.

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
2. Add a `<zkvm>-standards` backend to `src/runner/src/backends.rs` that feeds the input to that
   zkVM and reads its verdict and public output, and add its name to `src/runner/src/main.rs`.
3. Add the vendor library path, the backend and the executor to
   `src/run-eth-act-standards-tests.sh`.

## Accelerator vectors

`accelerators/vectors/*.h` are generated files. Regenerate them with:

```bash
uv run --no-project --with pycryptodome --with ecdsa tests/eth-act-standards/tools/gen_accel_vectors.py
```

The script lists the sources for every case. Most cases come from two sets of precompile test
data, converted to the C interface:

- go-ethereum `core/vm/testdata/precompiles` at tag v1.17.6, for every precompile;
- ethereum/execution-specs (EEST) `tests/` at tag `tests@v20.0.2`, for the EIP-2537 BLS12-381,
  EIP-7883 modexp and EIP-4844 KZG vectors. EEST has no JSON vectors for bn254, blake2f and
  ecrecover (only Python test parameters), so those come from go-ethereum only.

The script keeps the go-ethereum cases and adds selected EEST cases. It skips a case whose input
is already present, and each case label starts with its source (`geth` or `eest`). An EEST KZG
input error (`output: null`) is expected to be rejected, like an invalid proof.

`tools/accel_vector_sources.json` pins these files: the commit of each source and the sha256 of
each file. The script downloads each file at that commit, checks the sha256, and stops on a
mismatch. It caches the files in `~/.cache/eth-act-standards-vectors`.

Where the C interface does not define a behavior, the
tests follow the EVM precompile:

- EIP-2537 field elements are 48 bytes, without the 16 zero bytes of padding.
- BN254 G2 coordinates use the EVM order (imaginary part first).
- A zero `modexp` modulus gives an all-zero result.
- A `blake2f` final flag other than 0 or 1 must return a failure status.
- A signature, pairing or KZG check that is invalid may fail in either of two ways: it can
  return a failure status, or it can return success with `verified == false`.
