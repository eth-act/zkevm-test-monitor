# I/O and base standards verification

PR revision `e81a37cd6e72b5d188d62944e229b4929682ae96`.
The table lists only the `io` group. Vendor executable inputs and pins are identical across PRs #83–#85. The results were collected at #85's handoff revision `e81a37cd6e72b5d188d62944e229b4929682ae96`. The Pico result is from Slurm job 61.

| Vendor | Group verdicts passed | Group cases with results | Scope |
| --- | ---: | ---: | --- |
| openvm | 16 | 19 | Full mode |
| zisk | 16 | 19 | Full mode |
| sp1 | 19 | 19 | Full mode |
| pico | 19 | 19 | Full mode |

Requirement coverage at this exact PR revision exited 0.
The earlier OpenVM, ZisK and SP1 base-history append is available. [Published history commit](https://github.com/eth-act/zkevm-test-monitor/commit/98e2c3907d7fdbf2246e26c67ff742929a37db5d)

The full base runs cover I/O, accelerators, and memory.

| Vendor | Base suite verdicts | Proofs passed / attempted | Verifications passed / attempted |
| --- | ---: | ---: | ---: |
| openvm | 43/53 | 43/43 | 43/43 |
| zisk | 47/53 | 44/46 | 44/44 |
| sp1 | 49/52 | 49/49 | 49/49 |
| pico | 53/53 | 50/50 | 50/50 |

SP1's execute-only run covered all 53 base guests. Its separate full-mode run covered 52 guests. The G2 MSM proof is deferred because the previous prover used 130.5 GiB of RAM.

Pico logs and metrics are in `/home/devops/zkvm-runs/standards-prs.UqWIez/pr-85-pico` on beast-01.
