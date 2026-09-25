# eth-act standards tests

These tests check the guest interfaces that the
[EIP-8025 readiness review](https://github.com/jsign/eip-8025/blob/jsign-readiness/READINESS.md#zkvms)
asks of each zkVM. It covers three
[eth-act/zkevm-standards](https://github.com/eth-act/zkevm-standards) items, pinned in
`include/STANDARDS_COMMIT`:

| Group | Standard | Tests |
|---|---|---|
| `io/` | [I/O interface](https://github.com/eth-act/zkevm-standards/tree/main/standards/io-interface) (`zkvm_io.h`) | input sizes 0, 1, 13 and 64 KiB; `read_input` idempotence; echo; split, byte-wise and zero-length writes; outputs of 257 and 1024 bytes |
| `accelerators/` | [C interface for accelerators](https://github.com/eth-act/zkevm-standards/tree/main/standards/c-interface-accelerators) (`zkvm_accelerators.h`) | one program for each of the 19 functions, with valid and invalid known-answer cases |
| `memory/` | [Accelerated memory operations](https://github.com/eth-act/zkevm-standards/tree/main/standards/accelerated-memory-operations) | `memcpy`, `memmove`, `memset` and `memcmp` over all alignments and lengths 0..72, plus link resolution against weak decoys |

The suite runs execution only. It does not prove.

## How a test works

Each test is a small, standalone C program. It links only against the vendor's static library,
through the standard headers in `include/`. The host feeds it the test's I/O test vectors:
`<name>.input` is the private input (default: empty), and the public output must equal
`<name>.expected` (default: the 4 bytes `PASS`).

- A self-checking program writes `PASS`. On failure it writes `FAIL`, a little-endian u32
  check id and an optional label (`include/test_verdict.h`).
- An I/O program writes data-dependent output. `io/write_io_vectors.py` writes its input and its
  expected output.
- If the program never finishes, its output does not match, so the test fails.

ZisK has a fixed public output area of 64 u32 words with zero padding. On ZisK, the runner
therefore accepts output that equals the expected bytes followed by zero bytes.

SP1 public values are a variable-length stream, so on SP1 the output must equal the expected
bytes exactly.

OpenVM public values are a fixed area of 256 bytes with zero padding (ere's VM config), so the
runner compares them as for ZisK.

## Platforms

| zkVM | Vendor library | Host |
|---|---|---|
| ZisK | `ziskos-staticlib` + ZisK's own linker script at tag v1.3.0-alpha, the version eth-act/ere pins | `ziskemu` at the same tag (`binaries/zisk-eth-act-standards-emu`) |
| SP1 | zkEVM SDK `libzkevm.a` + `zkvm.ld` (`make sdk` in `zkevm/`) at upstream tag v6.6.0, the version eth-act/ere pins | `sp1-eth-act-standards-executor` (`platforms/sp1/executor`) |
| OpenVM | none from OpenVM; eth-act/ere's `ere-platform-openvm` at a fixed ere commit, over OpenVM tag v2.1.0-preview | `openvm-eth-act-standards-executor` (`platforms/openvm/executor`) |

The ZisK image pins its own ZisK tag, not the monitor's ZisK pin for the ACT4 suites. It
builds `ziskemu` (execute only) at that tag and copies it and its shared libraries to
`binaries/`.

The SDK is not in the monitor's SP1 fork (v6.1.0), so the SP1 image pins its own SP1 tag.
`sp1-eth-act-standards-executor` is built in the same image and copied to `binaries/`. It runs the guest in
SP1's minimal executor at that tag and passes the input as one stdin chunk, because
`read_input` returns only the first chunk.

OpenVM ships no C library for guests. Its own C-interface PRs
([#3075](https://github.com/openvm-org/openvm/pull/3075) to #3080) were closed unmerged. The
OpenVM results therefore test eth-act/ere's C layer on OpenVM's guest libraries, not an OpenVM
deliverable, and each history run says so in `notes`. `platforms/openvm/vendor` builds
`ere-platform-openvm` as a static library, the way ere compiles OpenVM guests with a stock
nightly toolchain. Everything in it comes from ere and OpenVM (`_start`, allocator, panic
handler, the `zkvm_*` accelerators, and `openvm-mem` for `memcpy` and friends), except for
`read_input` and `write_output`. These two functions forward to ere's `OpenVMPlatform`:

- `read_input` reads the input once and returns the same buffer on each call.
- `write_output` appends to a buffer and reveals the whole buffer again, because ere reveals
  from byte 0 on each call. ere limits the output to 256 bytes.

There is no linker script: OpenVM guests link with the default layout and `-Ttext=0x00200800`.
`openvm-eth-act-standards-executor` runs the guest in OpenVM's SDK executor, with the VM config that ere's
prover uses and the input as one input vector.

## Running

```bash
./run eth-act-standards-tests zisk      # only these tests
./run eth-act-standards-tests sp1 openvm
./run eth-act-standards-tests           # every zkVM with a platform
./run tests zisk                        # ISA tests, then these tests
```

The results go to `test-results/<zkvm>/results-eth-act-standards.json` and
`data/history/<zkvm>-eth-act-standards.json`. The dashboard shows one column per group.

## Adding a zkVM

1. Add `platforms/<zkvm>/`:
   - a `Dockerfile` that builds the vendor library and runs `build-guests.sh <zkvm> /elfs`;
   - a `platform.sh` that sets `CC`, `AR`, `CFLAGS`, `LINKER_SCRIPT`, `VENDOR_LIB`, `LDFLAGS`
     and `LIBS`;
   - a linker script, unless the vendor links without one (then `LINKER_SCRIPT` is empty).
2. Add a `run_<zkvm>` function to `act4-runner/src/eth_act_standards.rs` that feeds the input to
   that zkVM and reads its public output, and add it to `eth-act-standards-runner`
   (`act4-runner/src/bin/eth-act-standards-runner.rs`).
3. Add the executor to `src/run-eth-act-standards-tests.sh`.

## Accelerator vectors

`accelerators/vectors/*.h` are generated files. Regenerate them with:

```bash
uv run --no-project --with pycryptodome --with ecdsa eth-act-standards-tests/tools/gen_accel_vectors.py
```

The script lists the sources for every case. Most cases come from go-ethereum's precompile
test data, converted to the C interface. Where the C interface does not define a behavior, the
tests follow the EVM precompile:

- EIP-2537 field elements are 48 bytes, without the 16 zero bytes of padding.
- BN254 G2 coordinates use the EVM order (imaginary part first).
- A zero `modexp` modulus gives an all-zero result.
- A `blake2f` final flag other than 0 or 1 must return a failure status.
- A signature, pairing or KZG check that is invalid may fail in either of two ways: it can
  return a failure status, or it can return success with `verified == false`.
