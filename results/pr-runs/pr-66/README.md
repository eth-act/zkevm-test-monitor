# Instruction-address-misaligned verification

Slurm jobs 52 and 53 tested this PR at `a3aafb9f933b2a2463a9380a8f1b6ed5400b190b` with ere v0.20.2. Each vendor had one GPU. Job 52 ran the 18-case misaligned suite in execute and full mode. Job 53 ran the unfiltered vendor ACT4 pipeline, which verifies the standard ISA suite and executes the misaligned suite.

| Vendor | Misaligned execute verdicts | Aligned control proofs verified | Misaligned proof outcomes | Standard ISA proofs verified |
| --- | ---: | ---: | --- | ---: |
| OpenVM | 18/18 | 9/9 | Nine refused | 72/72 |
| ZisK | 18/18 | 9/9 | Nine setup errors | 72/72 |
| SP1 | 9/18 | 9/9 | Nine fatal errors | 63/72 |
| Pico | 18/18 | 9/9 | Nine refused | 72/72 |

The ZisK verdicts include six emulator linker errors before guest execution. SP1's standard ISA results include eight misaligned-memory execution failures and the known `I-fence-00` proof failure. Job 52 ended with exit 3 for SP1's host errors. Job 53 completed and generated eight history entries in the disposable worktrees. Both records are in `results.json`.
