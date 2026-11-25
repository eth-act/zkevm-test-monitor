# Guard regions verification

PR revision `ad36433f5707c096b008c0ead7ef5f4432eee68a`.
Slurm job 57 used one GPU per vendor and ere v0.20.2.
Full mode, selected `io-echo guard`. The I/O echo is a positive proof control.

| Vendor | Passed | Proofs verified | Prover RAM / GPU peak (GiB) | Run status |
| --- | ---: | ---: | ---: | --- |
| openvm | 1/10 | 5 | 1.3 / 2.11 | All selected outcomes recorded |
| zisk | — | — | — / 0.0 | Guest build could not resolve `_init_stack_bottom` |
| sp1 | 1/10 | 1 | 11.75 / 10.7 | All selected outcomes recorded |
| pico | 5/10 | 1 | 31.07 / 29.09 | All selected outcomes recorded |

Pico's unselected full standards run (Slurm 63) recorded 75/85 passing verdicts, 58 verified proofs, and peak prover RAM/GPU of 66.93 / 29.88 GiB.
The run appended one dashboard history entry, preserved in the evidence archive.

Pico met the expected verdicts for the four null-guard cases. It failed the five stack-guard cases.

The earlier unselected OpenVM standards and vendor ISA history are already available. The ZisK unselected standards build stopped and SP1's prior standards proof run selected the added groups. [Published history commit](https://github.com/eth-act/zkevm-test-monitor/commit/4935e6bf60ae06aa7c115e03087a3cd765d7ccbd)

Logs, per-test details, and retained ELFs are in `/home/devops/zkvm-runs/standards-prs.UqWIez/pr-62` on beast-01.
