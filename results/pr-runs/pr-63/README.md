# Termination semantics verification

Slurm job 51 ran on all four Beasts with one GPU per vendor. It tested this PR at `026b9552696f63bbedaf44a405292b62bdbe560f` using ere v0.20.2. The seven selected cases are the six termination tests and `io-echo` as an aligned positive proof control.

| Vendor | Passed | Verified proofs | Finding |
| --- | ---: | ---: | --- |
| OpenVM | 4/7 | 2 | `term-main-nonzero` produced a proof that verified as a successful execution. The test failed. |
| ZisK | 6/7 | 1 | The `term-main-nonzero` proof request hit an ASM setup error. |
| SP1 | 3/7 | 1 | Three cases had host errors. |
| Pico | 4/7 | 1 | Two cases had host errors. |

All four verified `io-echo`. The case lists and runner classifications are in `results.json`.
