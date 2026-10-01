# Arm optimized-routines string tests

These files come from [ARM-software/optimized-routines](https://github.com/ARM-software/optimized-routines)
at commit `375f32ed2f7098090f41795ad363822752a25a65` (license: `LICENSE`, MIT OR Apache-2.0 WITH
LLVM-exception). Arm uses these tests to check its optimized string routines. The `mem-aor-*.c`
guests in `memory/` include them.

| File | Origin |
|---|---|
| `memcpy.c`, `memmove.c`, `memset.c`, `memcmp.c` | `string/test/`, unchanged |
| `stringlib.h` | `string/include/`, unchanged |
| `LICENSE` | unchanged |
| `mte.h` | ours: the upstream non-MTE path, with a static arena in place of `malloc` |
| `stringtest.h` | ours: the upstream error reporting, with its own `isprint` in place of `<ctype.h>` |

`build-guests.sh` makes one change when it builds the guests: it replaces `#define LEN 250000`
with `#define LEN 1024`. With the upstream `LEN`, each test runs billions of guest
instructions. With 1024, the lengths are 0 to 99, 100, 200, 400 and 800.

To update, download the four tests, `stringlib.h` and `LICENSE` at a new commit, and change the
commit above.

## What the tests do not check

The tests fill buffers with `'a' + i % 23` (bytes 0x61 to 0x77). The `mem-*.c` guests cover
what the upstream tests do not:

| Gap in the upstream tests | Covered by |
|---|---|
| `memcmp` never sees a byte of 0x80 or more, so a signed comparison passes | `mem-memcmp.c` |
| `memcmp` has a difference only at the first, middle or last byte | `mem-memcmp.c` |
| `memset` never fills a byte of 0x80 or more (fill values `0`, `0x25`, `0xaa25`) | `mem-memset.c` |
| `memcpy` and `memcmp` are not checked for writes to their inputs | `mem-memcpy.c`, `mem-memcmp.c` |
| No guard bytes before an aligned destination | all four `mem-*.c` |
