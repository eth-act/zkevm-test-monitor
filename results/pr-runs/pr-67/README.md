# Memory layout verification

PR revision `5e0f3890203b6fc88d3686dc3db2266d70dc0886`.
Slurm job 56 used one GPU per vendor and ere v0.20.2.
Full mode, selected `io-echo layout`. The I/O echo is a positive proof control.

| Vendor | Passed | Proofs verified | Prover RAM / GPU peak (GiB) | Run status |
| --- | ---: | ---: | ---: | --- |
| openvm | 1/3 | 1 | 1.29 / 2.07 | All selected outcomes recorded |
| zisk | — | — | — / 0.0 | Guest build could not resolve `_init_stack_bottom` |
| sp1 | 2/3 | 2 | 11.7 / 10.86 | All selected outcomes recorded |
| pico | — | — | — / 0.0 | The pinned Pico platform has no memory profile for this group |

Logs, per-test details, and retained ELFs are in `/home/devops/zkvm-runs/standards-prs.UqWIez/pr-67` on beast-01.
