# ELF loading and validation verification

PR revision `682a99fb557e6779b2b2bbd96261844966d427f2`.
Slurm job 55 used one GPU per vendor and ere v0.20.2.
Full mode, selected `io-echo elf`. The I/O echo is a positive proof control.

| Vendor | Passed | Proofs verified | Prover RAM / GPU peak (GiB) | Run status |
| --- | ---: | ---: | ---: | --- |
| openvm | 18/32 | 19 | 1.33 / 2.11 | All selected outcomes recorded |
| zisk | — | — | — / 0.0 | Guest build could not resolve `_init_stack_bottom` |
| sp1 | 14/32 | 14 | 11.92 / 10.86 | All selected outcomes recorded. Runner reported host errors |
| pico | — | — | — / 0.0 | The pinned Pico platform has no memory profile for this group |

Logs, per-test details, and retained ELFs are in `/home/devops/zkvm-runs/standards-prs.UqWIez/pr-64` on beast-01.
