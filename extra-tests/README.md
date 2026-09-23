# act-extra: EIP-8025 zkVM interface tests

act-extra checks the guest interfaces that the
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
through the standard headers in `include/`. The host feeds it `<name>.input` (default: empty)
and compares its public output with `<name>.expected` (default: the 4 bytes `PASS`).

- A self-checking program writes `PASS`. On failure it writes `FAIL`, a little-endian u32
  check id and an optional label (`include/extra_test.h`).
- An I/O program writes data-dependent output. `io/sidecars.py` generates its input and its
  expected output.
- If the program never finishes, its output does not match, so the test fails.

ZisK has a fixed public output area of 64 u32 words with zero padding. On ZisK, the runner
therefore accepts output that equals the expected bytes followed by zero bytes.

## Running

```bash
./run extra zisk          # only this suite
./run test zisk           # ACT4 suites, then this suite (EXTRA=0 skips it)
```

The results go to `test-results/<zkvm>/results-act4-extra.json` and
`data/history/<zkvm>-act-extra.json`. The dashboard shows one column per group.

## Adding a zkVM

1. Add `platforms/<zkvm>/`:
   - a `Dockerfile` that builds the vendor library and runs `build.sh <zkvm> /elfs`;
   - a `platform.sh` that sets `CC`, `AR`, `CFLAGS`, `LINKER_SCRIPT`, `VENDOR_LIB`, `LDFLAGS`
     and `LIBS`;
   - a linker script.
2. Teach `act4-runner --io-sidecars` to feed input to that zkVM and read its public output
   (`act4-runner/src/extra.rs`).
3. Add the emulator binary to `src/extra.sh`.

## Accelerator vectors

`accelerators/vectors/*.h` are generated files. Regenerate them with:

```bash
uv run --no-project --with pycryptodome --with ecdsa extra-tests/tools/gen_accel_vectors.py
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
