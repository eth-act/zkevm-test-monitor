# Accelerator requirements verification

PR revision `e7f9e97b2cb3b89f700731746d08998d9f6d270e`.
The table lists only the `accelerators` group. Vendor executable inputs and pins are identical across PRs #83–#85. The results were collected at #85's handoff revision `e81a37cd6e72b5d188d62944e229b4929682ae96`. The Pico result is from Slurm job 61.

| Vendor | Group verdicts passed | Group cases with results | Scope |
| --- | ---: | ---: | --- |
| openvm | 19 | 22 | Full mode |
| zisk | 20 | 22 | Full mode |
| sp1 | 18 | 21 | G2 MSM proof deferred by RAM. Its execute-only case passed. |
| pico | 22 | 22 | Full mode |

Requirement coverage at this exact PR revision exited 0.
The earlier OpenVM, ZisK and SP1 base-history append is available. [Published history commit](https://github.com/eth-act/zkevm-test-monitor/commit/98e2c3907d7fdbf2246e26c67ff742929a37db5d)

The executable reference has no accelerator semantics. The existing PR records those cases as unspecified on the reference.

Pico logs and metrics are in `/home/devops/zkvm-runs/standards-prs.UqWIez/pr-85-pico` on beast-01.
