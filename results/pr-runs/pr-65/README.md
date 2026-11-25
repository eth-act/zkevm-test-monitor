# Static library and runtime linking verification

PR revision `7e3f8089f827cd58edefc2aa10e1baeddf063531`.
Slurm job 54 used one GPU per vendor and ere v0.20.2.
Full mode, selected `io-echo library runtime runtime-lld`. The I/O echo is a positive proof control.

| Vendor | Passed | Proofs verified | Prover RAM / GPU peak (GiB) | Run status |
| --- | ---: | ---: | ---: | --- |
| openvm | 6/19 | 5 | 1.31 / 2.08 | All selected outcomes recorded |
| zisk | 18/19 | 9 | 48.08 / 30.03 | All selected outcomes recorded |
| sp1 | 11/19 | 4 | 11.93 / 10.95 | All selected outcomes recorded |
| pico | 16/18 | 9 | 33.3 / 29.09 | All selected outcomes recorded |

Logs, per-test details, and retained ELFs are in `/home/devops/zkvm-runs/standards-prs.UqWIez/pr-65` on beast-01.
