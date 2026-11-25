# Memory-operation requirements verification

PR revision `8d744b781619c4d7786dc0933b9c23a80376842c`.
The table lists only the `memory` group. Vendor executable inputs and pins are identical across PRs #83–#85. The results were collected at #85's handoff revision `e81a37cd6e72b5d188d62944e229b4929682ae96`. The Pico result is from Slurm job 61.

| Vendor | Group verdicts passed | Group cases with results | Scope |
| --- | ---: | ---: | --- |
| openvm | 8 | 12 | Full mode |
| zisk | 11 | 12 | Full mode |
| sp1 | 12 | 12 | Full mode |
| pico | 12 | 12 | Full mode |

Requirement coverage at this exact PR revision exited 0.
The earlier OpenVM, ZisK and SP1 base-history append is available. [Published history commit](https://github.com/eth-act/zkevm-test-monitor/commit/98e2c3907d7fdbf2246e26c67ff742929a37db5d)

The slow reference memory run cited in this PR provides the reference comparison.

Pico logs and metrics are in `/home/devops/zkvm-runs/standards-prs.UqWIez/pr-85-pico` on beast-01.
